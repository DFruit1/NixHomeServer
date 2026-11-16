/* Virtual logger: Quectel EC21 AT-command emulator on UART1.
 *
 * The firmware's real driver (Drivers/BSP/GSM/Src/Quectel_EC21.c) talks to
 * this emulator byte by byte; MQTT commands are mapped onto a real
 * libmosquitto client connected to the test broker:
 *   AT+QMTCFG "session"/"keepalive"/"will"/"willex" -> clean_session,
 *       keepalive and Last Will of the client
 *   AT+QMTOPEN  -> remembered (the TCP connect happens with QMTCONN)
 *   AT+QMTCONN  -> mosquitto_connect(client id, user, password), CONNACK
 *                  -> +QMTCONN: 0,0,<rc>
 *   AT+QMTSUB   -> SUBSCRIBE, SUBACK -> +QMTSUB: 0,<id>,0,<granted>...
 *   AT+QMTPUB / AT+QMTPUBEX (text with Ctrl-Z, or <len> bytes after '>')
 *               -> PUBLISH QoS 1, PUBACK -> +QMTPUB(EX): 0,<id>,0
 *   PUBLISH from the broker -> +QMTRECV: 0,<id>,"<topic>",<len>,"<payload>"
 *   AT+QMTDISC  -> DISCONNECT (no Last Will); AT+QMTCLOSE -> socket closed
 *                  without DISCONNECT (the broker publishes the Last Will)
 *   lost link   -> +QMTSTAT: 0,1
 * TLS (AT+QSSLCFG, CA upload) is acknowledged but not performed: the test
 * broker listens in plain TCP. Registration, signal, network time, identity
 * and GNSS answers come from vl_cfg. Fault injection (vl_modem_fault):
 *   drop:<topic suffix>:<n>   n-th matching publish is acknowledged to the
 *                             logger but never reaches the broker
 *   fail:<topic suffix>:<n>   n-th matching publish reports result 2
 *   dup:<topic suffix>:<n>    n-th matching publish is delivered twice
 *   cut:<topic suffix>:<n>    the link drops (no DISCONNECT) instead of the
 *                             n-th matching publish: Last Will, +QMTSTAT
 *   clear                     removes every rule */
#include <mosquitto.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include "main.h"
#include "vl.h"

/* ---------------------------------------------------------------- output */

static void say_n(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) vl_uart_rx((uint8_t)s[i]);
}
static void say(const char *s) { say_n(s, strlen(s)); }
static int starts(const char *s, const char *p) { return strncmp(s, p, strlen(p)) == 0; }

/* ------------------------------------------------------------------ state */

enum { M_CMD, M_PUB_TEXT, M_PUB_LEN, M_WILL, M_UPL };
static int mode = M_CMD;
static int echo = 1, cfun = 1, gps_on;
static bool pdp_active, opened;
static char line[1024];
static size_t line_len;
static int lf_after_cr;
static size_t data_left;

/* MQTT client configuration (QMTCFG) */
static int clean_session = 1, keepalive = 120;
static bool will_set;
static int will_qos, will_retain;
static char will_topic[128];
static char will_payload[256];
static size_t will_len;

/* publish being collected */
static unsigned pub_id, pub_qos, pub_retain;
static int pub_ex;
static char pub_topic[160];
static uint8_t pub_data[4096];
static size_t pub_len;

static struct mosquitto *mq;
static bool mq_connected;
static int connack_rc = -1;
static int sub_mid = -1, sub_count;
static int sub_granted[8];
static int last_puback_mid = -1;

/* downlink FIFO (main thread only) */
typedef struct dl {
    struct dl *next;
    char topic[160];
    int mid;
    size_t len;
    char payload[];
} dl_t;
static dl_t *dl_head, *dl_tail;
static bool pending_stat; /* +QMTSTAT owed */

/* ---------------------------------------------------------------- faults */

typedef struct {
    char kind[8];
    char suffix[64];
    int nth, seen;
} rule_t;
static rule_t rules[16];
static int n_rules;

void vl_modem_fault(const char *spec) {
    if (strcmp(spec, "clear") == 0) {
        n_rules = 0;
        return;
    }
    if (n_rules == 16) return;
    rule_t *r = &rules[n_rules];
    memset(r, 0, sizeof *r);
    const char *a = strchr(spec, ':');
    const char *b = a ? strrchr(spec, ':') : NULL;
    if (!a || b == a) return;
    snprintf(r->kind, sizeof r->kind, "%.*s", (int)(a - spec), spec);
    snprintf(r->suffix, sizeof r->suffix, "%.*s", (int)(b - a - 1), a + 1);
    r->nth = atoi(b + 1);
    n_rules++;
}

static bool ends_with(const char *s, const char *suf) {
    size_t n = strlen(s), m = strlen(suf);
    return m <= n && strcmp(s + n - m, suf) == 0;
}

/* The rule that applies to this publish ("" when none). */
static const char *publish_fault(const char *topic) {
    const char *hit = "";
    for (int i = 0; i < n_rules; i++) {
        rule_t *r = &rules[i];
        if (!ends_with(topic, r->suffix)) continue;
        if (++r->seen == r->nth) hit = r->kind;
    }
    return hit;
}

/* ----------------------------------------------------------- mosquitto */

static void on_connect(struct mosquitto *m, void *o, int rc) {
    (void)m;
    (void)o;
    connack_rc = rc;
    mq_connected = rc == 0;
}

static void on_disconnect(struct mosquitto *m, void *o, int rc) {
    (void)m;
    (void)o;
    if (mq_connected && rc != 0) pending_stat = true;
    mq_connected = false;
}

static void on_publish(struct mosquitto *m, void *o, int mid) {
    (void)m;
    (void)o;
    last_puback_mid = mid;
}

static void on_subscribe(struct mosquitto *m, void *o, int mid, int n, const int *granted) {
    (void)m;
    (void)o;
    if (mid != sub_mid) return;
    sub_count = n > 8 ? 8 : n;
    for (int i = 0; i < sub_count; i++) sub_granted[i] = granted[i];
    sub_mid = -2; /* done */
}

static void on_message(struct mosquitto *m, void *o, const struct mosquitto_message *msg) {
    (void)m;
    (void)o;
    dl_t *d = malloc(sizeof *d + (size_t)msg->payloadlen + 1);
    if (!d) return;
    d->next = NULL;
    snprintf(d->topic, sizeof d->topic, "%s", msg->topic);
    d->mid = msg->mid;
    d->len = (size_t)msg->payloadlen;
    memcpy(d->payload, msg->payload, d->len);
    d->payload[d->len] = '\0';
    if (dl_tail) dl_tail->next = d;
    else dl_head = d;
    dl_tail = d;
    vl_time_activity();
}

static void mq_loop(int timeout_ms) {
    if (!mq) return;
    int rc = mosquitto_loop(mq, timeout_ms, 1);
    if (rc != MOSQ_ERR_SUCCESS && mq_connected) {
        mq_connected = false;
        pending_stat = true;
    }
}

/* Wait (real time) until done() or timeout. */
static bool mq_wait(bool (*done)(void), int timeout_ms) {
    struct timespec t0, t;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        if (done()) return true;
        if (!mq || (!mq_connected && connack_rc >= 0)) return done();
        mq_loop(20);
        clock_gettime(CLOCK_MONOTONIC, &t);
        if ((t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000 > timeout_ms) return done();
    }
}

static bool connack_seen(void) { return connack_rc >= 0; }
static bool suback_seen(void) { return sub_mid == -2; }
static int want_mid;
static bool puback_seen(void) { return last_puback_mid == want_mid; }

static void session_end(void) {
    if (mq) {
        mosquitto_destroy(mq);
        mq = NULL;
    }
    mq_connected = false;
    opened = false;
    vl_time_session(false);
}

/* Link lost without DISCONNECT: the broker sees the TCP connection close and
 * publishes the Last Will. */
static void link_cut(void) {
    if (mq) {
        int fd = mosquitto_socket(mq);
        if (fd >= 0) shutdown(fd, SHUT_RDWR);
    }
    vl_event("{\"ev\":\"link\",\"state\":\"cut\"}");
    session_end();
    pending_stat = true;
}

static bool mqtt_connect(const char *cid, const char *user, const char *pass) {
    connack_rc = -1;
    mq = mosquitto_new(cid, clean_session ? true : false, NULL);
    if (!mq) return false;
    mosquitto_int_option(mq, MOSQ_OPT_PROTOCOL_VERSION, MQTT_PROTOCOL_V311);
    mosquitto_connect_callback_set(mq, on_connect);
    mosquitto_disconnect_callback_set(mq, on_disconnect);
    mosquitto_publish_callback_set(mq, on_publish);
    mosquitto_subscribe_callback_set(mq, on_subscribe);
    mosquitto_message_callback_set(mq, on_message);
    if (vl_cfg.user[0]) mosquitto_username_pw_set(mq, vl_cfg.user, vl_cfg.pass);
    else if (user[0]) mosquitto_username_pw_set(mq, user, pass);
    if (will_set) mosquitto_will_set(mq, will_topic, (int)will_len, will_payload, will_qos, will_retain);
    if (mosquitto_connect(mq, vl_cfg.host, vl_cfg.port, keepalive) != MOSQ_ERR_SUCCESS) {
        session_end();
        return false;
    }
    mq_wait(connack_seen, 5000);
    vl_event("{\"ev\":\"link\",\"state\":\"%s\",\"rc\":%d,\"clean\":%d,\"will\":%d}",
             mq_connected ? "up" : "refused", connack_rc, clean_session, will_set);
    if (mq_connected) vl_time_session(true);
    return true;
}

/* ------------------------------------------------------------- publishes */

static void publish_done(void) {
    char reply[96];
    const char *urc = pub_ex ? "+QMTPUBEX" : "+QMTPUB";
    pub_data[pub_len] = 0;
    say("\r\nOK\r\n");
    vl_time_activity();
    const char *fault = publish_fault(pub_topic);
    char *hex = malloc(2 * pub_len + 1);
    vl_hex(hex, pub_data, pub_len);
    vl_event("{\"ev\":\"pub\",\"topic\":\"%s\",\"retain\":%u,\"len\":%zu,\"fault\":\"%s\",\"hex\":\"%s\"}", pub_topic,
             pub_retain, pub_len, fault, hex);
    free(hex);
    int result = 2;
    if (strcmp(fault, "cut") == 0) {
        link_cut();
        return;
    }
    if (strcmp(fault, "drop") == 0) {
        result = 0;
    } else if (strcmp(fault, "fail") == 0) {
        result = 2;
    } else if (mq && mq_connected) {
        int copies = strcmp(fault, "dup") == 0 ? 2 : 1;
        result = 0;
        for (int i = 0; i < copies && result == 0; i++) {
            int mid = 0;
            if (mosquitto_publish(mq, &mid, pub_topic, (int)pub_len, pub_data, (int)pub_qos, pub_retain != 0) !=
                MOSQ_ERR_SUCCESS) {
                result = 2;
                break;
            }
            want_mid = mid;
            if (pub_qos && !mq_wait(puback_seen, 10000)) result = 2;
        }
    }
    snprintf(reply, sizeof reply, "\r\n%s: 0,%u,%d\r\n", urc, pub_id, result);
    say(reply);
}

static int parse_pub(const char *c, size_t *len) {
    const char *p = strchr(c, '=') + 1;
    char *q;
    (void)strtoul(p, &q, 10);
    pub_id = (unsigned)strtoul(q + 1, &q, 10);
    pub_qos = (unsigned)strtoul(q + 1, &q, 10);
    pub_retain = (unsigned)strtoul(q + 1, &q, 10);
    if (q[0] != ',' || q[1] != '"') return 0;
    const char *t = q + 2, *e = strchr(t, '"');
    if (!e || (size_t)(e - t) >= sizeof pub_topic) return 0;
    memcpy(pub_topic, t, (size_t)(e - t));
    pub_topic[e - t] = '\0';
    if (e[1] == ',') {
        *len = strtoul(e + 2, NULL, 10);
        return 6;
    }
    return 5;
}

/* ------------------------------------------------------------- commands */

static void reg_reply(const char *what) {
    char r[64];
    int stat = (vl_cfg.registered && vl_cfg.sim_present && cfun == 1) ? 1 : 2;
    snprintf(r, sizeof r, "+%s: 0,%d\r\n\r\nOK\r\n", what, stat);
    say(r);
}

static void time_reply(const char *cmd) {
    char r[96];
    if (!vl_cfg.net_time || cfun != 1) {
        if (starts(cmd, "AT+CCLK")) say("+CCLK: \"80/01/06,00:01:02+00\"\r\n\r\nOK\r\n");
        else say("+QLTS: \"\"\r\n\r\nOK\r\n");
        return;
    }
    time_t t = (time_t)(vl_world_ms() / 1000);
    struct tm tm;
    gmtime_r(&t, &tm);
    if (starts(cmd, "AT+CCLK"))
        snprintf(r, sizeof r, "+CCLK: \"%02d/%02d/%02d,%02d:%02d:%02d+00\"\r\n\r\nOK\r\n", tm.tm_year % 100,
                 tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
    else
        snprintf(r, sizeof r, "+QLTS: \"%04d/%02d/%02d,%02d:%02d:%02d+00,0\"\r\n\r\nOK\r\n", tm.tm_year + 1900,
                 tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
    say(r);
}

static void gnss_reply(void) {
    char r[192];
    if (!gps_on || !vl_cfg.gnss_fix) {
        say("+CME ERROR: 516\r\n");
        return;
    }
    time_t t = (time_t)(vl_world_ms() / 1000);
    struct tm tm;
    gmtime_r(&t, &tm);
    snprintf(r, sizeof r, "+QGPSLOC: %02d%02d%02d.0,%.7f,%.7f,%.1f,%d.0,%d,0.00,0.0,0.0,%02d%02d%02d,%02d\r\n\r\nOK\r\n",
             tm.tm_hour, tm.tm_min, tm.tm_sec, vl_cfg.lat, vl_cfg.lon, vl_cfg.hdop, vl_cfg.alt_m, vl_cfg.fix,
             tm.tm_mday, tm.tm_mon + 1, tm.tm_year % 100, vl_cfg.sats);
    say(r);
}

static void on_command(const char *c) {
    char reply[512];
    if (!vl_cfg.modem_powered) return; /* no +12 V: silent */
    if (echo) {
        say(c);
        say("\r");
    }
    say("\r\n");
    if (!starts(c, "AT")) {
        say("ERROR\r\n");
    } else if (strcmp(c, "AT") == 0 || starts(c, "AT+CMEE") || starts(c, "AT+CTZU") || starts(c, "AT+QICSGP") ||
               starts(c, "AT+QSSLCFG") || starts(c, "AT+QCFG") || starts(c, "AT+QURCCFG")) {
        say("OK\r\n");
    } else if (starts(c, "ATE0")) {
        echo = 0;
        say("OK\r\n");
    } else if (starts(c, "AT+CFUN?")) {
        snprintf(reply, sizeof reply, "+CFUN: %d\r\n\r\nOK\r\n", cfun);
        say(reply);
    } else if (starts(c, "AT+CFUN=0")) {
        cfun = 0;
        pdp_active = false;
        if (mq) link_cut();
        say("OK\r\n");
    } else if (starts(c, "AT+CFUN=1")) {
        cfun = 1;
        say("OK\r\n");
    } else if (starts(c, "AT+CGSN")) {
        say("864292046589220\r\n\r\nOK\r\n");
    } else if (starts(c, "AT+QCCID")) {
        say(vl_cfg.sim_present ? "+QCCID: 8961018500218515572F\r\n\r\nOK\r\n" : "+CME ERROR: 10\r\n");
    } else if (starts(c, "AT+QGMR")) {
        say("EC21EFAR06A07M4G\r\n\r\nOK\r\n");
    } else if (starts(c, "AT+CSQ")) {
        snprintf(reply, sizeof reply, "+CSQ: %d,99\r\n\r\nOK\r\n", cfun == 1 ? vl_cfg.csq : 99);
        say(reply);
    } else if (starts(c, "AT+CEREG?")) {
        reg_reply("CEREG");
    } else if (starts(c, "AT+CREG?")) {
        reg_reply("CREG");
    } else if (starts(c, "AT+QLTS") || starts(c, "AT+CCLK?")) {
        time_reply(c);
    } else if (starts(c, "AT+QIACT?")) {
        say(pdp_active ? "+QIACT: 1,1,1,\"10.64.0.2\"\r\n\r\nOK\r\n" : "OK\r\n");
    } else if (starts(c, "AT+QIACT=1")) {
        bool ok = vl_cfg.registered && vl_cfg.sim_present && cfun == 1;
        pdp_active = ok;
        say(ok ? "OK\r\n" : "ERROR\r\n");
    } else if (starts(c, "AT+QGPS=1")) {
        if (gps_on) say("+CME ERROR: 504\r\n");
        else {
            gps_on = 1;
            say("OK\r\n");
        }
    } else if (starts(c, "AT+QGPSEND")) {
        gps_on = 0;
        say("OK\r\n");
    } else if (starts(c, "AT+QGPSLOC")) {
        gnss_reply();
    } else if (starts(c, "AT+QFDEL")) {
        say("+CME ERROR: 405\r\n");
    } else if (starts(c, "AT+QFUPL=")) {
        const char *p = strchr(c, ',');
        data_left = p ? strtoul(p + 1, NULL, 10) : 0;
        pub_len = 0;
        say("CONNECT\r\n");
        mode = M_UPL;
    } else if (starts(c, "AT+QMTCFG=\"session\"")) {
        clean_session = atoi(strrchr(c, ',') + 1);
        say("OK\r\n");
    } else if (starts(c, "AT+QMTCFG=\"keepalive\"")) {
        keepalive = atoi(strrchr(c, ',') + 1);
        say("OK\r\n");
    } else if (starts(c, "AT+QMTCFG=\"willex\"")) {
        /* "willex",<client>,<flag>,<qos>,<retain>,"<topic>",<len> */
        int client, flag;
        if (sscanf(c, "AT+QMTCFG=\"willex\",%d,%d,%d,%d,\"%127[^\"]\",%zu", &client, &flag, &will_qos,
                   &will_retain, will_topic, &data_left) != 6) {
            say("ERROR\r\n");
            return;
        }
        will_set = flag != 0;
        will_len = 0;
        mode = M_WILL;
        say("\r\n> ");
    } else if (starts(c, "AT+QMTCFG=\"will\"")) {
        int client, flag;
        if (sscanf(c, "AT+QMTCFG=\"will\",%d,%d,%d,%d,\"%127[^\"]\",\"%255[^\"]\"", &client, &flag, &will_qos,
                   &will_retain, will_topic, will_payload) != 6) {
            say("ERROR\r\n");
            return;
        }
        will_set = flag != 0;
        will_len = strlen(will_payload);
        say("OK\r\n");
    } else if (starts(c, "AT+QMTCFG")) {
        say("OK\r\n");
    } else if (starts(c, "AT+QMTOPEN?")) {
        if (opened) {
            snprintf(reply, sizeof reply, "+QMTOPEN: 0,\"%s\",%d\r\n\r\n", GWL_MQTT_HOST, GWL_MQTT_PORT);
            say(reply);
        }
        say("OK\r\n");
    } else if (starts(c, "AT+QMTOPEN=")) {
        say("OK\r\n");
        opened = pdp_active;
        say(opened ? "\r\n+QMTOPEN: 0,0\r\n" : "\r\n+QMTOPEN: 0,3\r\n");
    } else if (starts(c, "AT+QMTCONN?")) {
        if (mq && mq_connected) say("+QMTCONN: 0,3\r\n\r\n");
        else if (opened) say("+QMTCONN: 0,1\r\n\r\n");
        say("OK\r\n");
    } else if (starts(c, "AT+QMTCONN=")) {
        char cid[64] = "", user[64] = "", pass[128] = "";
        if (!opened || sscanf(c, "AT+QMTCONN=0,\"%63[^\"]\",\"%63[^\"]\",\"%127[^\"]\"", cid, user, pass) < 1) {
            say("ERROR\r\n");
            return;
        }
        say("OK\r\n");
        if (!mqtt_connect(cid, user, pass)) {
            say("\r\n+QMTSTAT: 0,1\r\n");
            opened = false;
            return;
        }
        snprintf(reply, sizeof reply, "\r\n+QMTCONN: 0,0,%d\r\n", connack_rc < 0 ? 3 : connack_rc);
        say(reply);
        if (!mq_connected) session_end();
    } else if (starts(c, "AT+QMTSUB=")) {
        unsigned id = 0;
        char *topics[8];
        int qos[8], n = 0;
        sscanf(c, "AT+QMTSUB=0,%u", &id);
        const char *p = c;
        while (n < 8 && (p = strchr(p, '"')) != NULL) {
            const char *e = strchr(p + 1, '"');
            if (!e) break;
            topics[n] = strndup(p + 1, (size_t)(e - p - 1));
            qos[n] = e[1] == ',' ? atoi(e + 2) : 0;
            n++;
            p = e + 1;
        }
        if (!mq || !mq_connected) {
            say("ERROR\r\n");
        } else {
            say("OK\r\n");
            sub_mid = -1;
            int mid = 0;
            mosquitto_subscribe_multiple(mq, &mid, n, topics, qos[0], 0, NULL);
            sub_mid = mid;
            mq_wait(suback_seen, 5000);
            int k = snprintf(reply, sizeof reply, "\r\n+QMTSUB: 0,%u,%d", id, suback_seen() ? 0 : 2);
            for (int i = 0; i < n && suback_seen(); i++)
                k += snprintf(reply + k, sizeof reply - (size_t)k, ",%d", i < sub_count ? sub_granted[i] : 128);
            strcat(reply, "\r\n");
            say(reply);
            vl_event("{\"ev\":\"sub\",\"n\":%d,\"granted\":%d}", n, sub_count ? sub_granted[0] : -1);
        }
        for (int i = 0; i < n; i++) free(topics[i]);
    } else if (starts(c, "AT+QMTPUBEX=?")) {
        say(vl_cfg.pubex ? "+QMTPUBEX: (0-5),(0-65535),(0-2),(0,1),\"topic\",(1-1500)\r\n\r\nOK\r\n"
                         : "+CME ERROR: 58\r\n");
    } else if (starts(c, "AT+QMTPUB=?")) {
        say(vl_cfg.publen ? "+QMTPUB: (0-5),(0-65535),(0-2),(0,1),\"topic\",(1-4096)\r\n\r\nOK\r\n"
                          : "+QMTPUB: (0-5),(0-65535),(0-2),(0,1),\"topic\"\r\n\r\nOK\r\n");
    } else if (starts(c, "AT+QMTPUBEX=") || starts(c, "AT+QMTPUB=")) {
        size_t len = 0;
        pub_ex = starts(c, "AT+QMTPUBEX=");
        int fields = parse_pub(c, &len);
        pub_len = 0;
        if (!fields || !mq || !mq_connected || (pub_ex && !vl_cfg.pubex) ||
            (!pub_ex && fields == 6 && !vl_cfg.publen) || len > sizeof pub_data - 1) {
            say("ERROR\r\n");
            return;
        }
        if (fields == 6) {
            mode = M_PUB_LEN;
            data_left = len;
        } else {
            mode = M_PUB_TEXT;
        }
        say("\r\n> ");
    } else if (starts(c, "AT+QMTDISC=")) {
        if (mq && mq_connected) {
            mosquitto_disconnect(mq);
            mq_loop(50);
        }
        vl_event("{\"ev\":\"link\",\"state\":\"disconnected\"}");
        session_end();
        say("OK\r\n\r\n+QMTDISC: 0,0\r\n");
    } else if (starts(c, "AT+QMTCLOSE=")) {
        if (mq) link_cut();
        pending_stat = false;
        say("OK\r\n\r\n+QMTCLOSE: 0,0\r\n");
    } else {
        say("OK\r\n");
    }
}

void vl_modem_tx(const uint8_t *d, size_t n) {
    for (size_t i = 0; i < n; i++) {
        uint8_t b = d[i];
        if (lf_after_cr) {
            lf_after_cr = 0;
            if (b == '\n') continue;
        }
        switch (mode) {
        case M_PUB_TEXT:
            if (b == 0x1B) {
                mode = M_CMD;
                say("\r\nOK\r\n");
            } else if (b == 0x1A) {
                mode = M_CMD;
                publish_done();
            } else if (pub_len < sizeof pub_data - 1) {
                pub_data[pub_len++] = b;
            }
            continue;
        case M_PUB_LEN:
            pub_data[pub_len++] = b;
            if (--data_left == 0) {
                mode = M_CMD;
                publish_done();
            }
            continue;
        case M_WILL:
            if (will_len < sizeof will_payload - 1) will_payload[will_len++] = (char)b;
            if (--data_left == 0) {
                will_payload[will_len] = '\0';
                mode = M_CMD;
                say("\r\nOK\r\n");
            }
            continue;
        case M_UPL:
            if (++pub_len, --data_left == 0) {
                char r[64];
                snprintf(r, sizeof r, "+QFUPL: %zu,3fa1\r\n\r\nOK\r\n", pub_len);
                say(r);
                mode = M_CMD;
            }
            continue;
        default:
            break;
        }
        if (b == '\r') {
            line[line_len] = '\0';
            lf_after_cr = 1;
            if (line_len) on_command(line);
            line_len = 0;
        } else if (b != '\n' && line_len < sizeof line - 1) {
            line[line_len++] = (char)b;
        }
    }
}

/* ------------------------------------------------------------------ poll */

void vl_modem_poll(void) {
    if (mq) mq_loop(0);
    if (mode != M_CMD) return;
    if (pending_stat) {
        pending_stat = false;
        if (mq) session_end();
        say("\r\n+QMTSTAT: 0,1\r\n");
        return;
    }
    if (!dl_head) return;
    dl_t *d = dl_head;
    dl_head = d->next;
    if (!dl_head) dl_tail = NULL;
    char *hex = malloc(2 * d->len + 1);
    vl_hex(hex, (const uint8_t *)d->payload, d->len);
    vl_event("{\"ev\":\"recv\",\"topic\":\"%s\",\"len\":%zu,\"hex\":\"%s\"}", d->topic, d->len, hex);
    free(hex);
    char head[256];
    snprintf(head, sizeof head, "\r\n+QMTRECV: 0,%d,\"%s\",%zu,\"", d->mid, d->topic, d->len);
    say(head);
    say_n(d->payload, d->len);
    say("\"\r\n");
    free(d);
    vl_time_activity();
}

bool vl_modem_rx_pending(void) { return dl_head != NULL || pending_stat; }
bool vl_modem_session(void) { return mq && mq_connected; }

void vl_modem_init(void) { mosquitto_lib_init(); }

void vl_modem_shutdown(void) {
    if (mq) link_cut();
    mosquitto_lib_cleanup();
}
