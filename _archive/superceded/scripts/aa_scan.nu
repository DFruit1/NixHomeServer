# scripts/aa_scan.nu
# nushell ≥ 0.95

let OUT = ($env.PWD | path join "apparmor-auto" "out")
mkdir $OUT | ignore

# Accept RFC3339/"yesterday"/"-2h"/etc.; default = since boot
export def main [--since: string = "boot", --until: string = "now"] {
  let since_arg = (if $since == "boot" { "-b" } else { ["--since", $since] })
  let until_arg = (if $until == "now" { [] } else { ["--until", $until] })

  # Pull kernel/audit lines and filter for AppArmor DENIED entries
  let raw = (do -i { ^journalctl -k -o short-iso @since_arg ...$since_arg @until_arg ...$until_arg } | to text)
  let lines = ($raw | lines | where ($it | str contains 'apparmor="DENIED"'))

  let parsed = $lines \
    | each {|line|
        # Example audit blob contains key="value" tokens; pull common ones
        let time = ($line | split column ' ' | get column1 | str trim) # first token is timestamp in short-iso
        let kvs = ($line
          | parse -r '.*?apparmor="DENIED"(?:\s|;)+(?P<rest>.*)$'
          | get rest.0
          | default ""
          | split row ' '
          | where ($it | str contains '=')
          | parse -r '^(?P<k>[a-zA-Z_\-]+)=(?:"(?P<vq>.*?)"|(?P<vn>[^\s;]+))'
          | each {|x| {k: ($x.k | str downcase), v: (if $x.vq != null {$x.vq} else {$x.vn}) }}
          | reduce -f {} {|it, acc| $acc | upsert $it.k $it.v }
        )
        {
          ts: $time,
          op: ($kvs.operation | default null),
          profile: ($kvs.profile | default null),
          name: ($kvs.name | default null),         # file/dir path
          exe: ($kvs.exe | default null),           # binary path
          comm: ($kvs.comm | default null),         # process name
          pid: ($kvs.pid | default null),
          requested: ($kvs.requested_mask | default null),
          denied: ($kvs.denied_mask | default null),
          capname: ($kvs.capname | default null),   # capabilities
          peer: ($kvs.peer | default null),
          info: ($kvs.info | default null)
        }
      }

  $parsed | to ndjson | save -f ($OUT | path join "denials.ndjson")
  print $"Saved ($parsed | length) denial records to apparmor-auto/out/denials.ndjson"
}
