#!/usr/bin/env python3
"""Synthetic capture fixture; run inside the pinned crawler's --network none.

Python deliberately uses the image's existing standard-library HTTP server,
without adding backend dependencies. Deep HTML MIME, warm API capture and a
valid favicon reproduce the fidelity regressions found in actual acceptance.
"""
import base64
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PIXEL = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j/0cAAAAASUVORK5CYII=")
HOME = """<!doctype html><html lang=en><meta charset=utf-8><title>Preservation fixture</title>
<link rel=stylesheet href=/site.css><main><h1>Preservation fixture</h1>
<p id=story>The original story remains readable offline.</p>
<button id=menu-toggle aria-expanded=false>Open menu</button><nav id=menu hidden><a href=/section/deep/page>Deep page</a></nav>
<button id=tab-toggle>Show detail</button><section id=detail hidden>Hidden content is needed after interaction.</section>
<button id=load-data>Load archived data</button><p id=data-result></p>
<aside id=advert class=advert>Advertisement region</aside><img src=/pixel.png alt="Preserved pixel">
<a href=/section/>Section</a></main><script src=/app.js></script><script src=/ad.js></script></html>"""
SCRIPT = """document.querySelector('#menu-toggle').onclick=function(){let n=document.querySelector('#menu');n.hidden=!n.hidden;this.setAttribute('aria-expanded',String(!n.hidden));};
document.querySelector('#tab-toggle').onclick=()=>document.querySelector('#detail').hidden=false;
document.querySelector('#load-data').onclick=async()=>{let r=await fetch('/api/detail');document.querySelector('#data-result').textContent=(await r.json()).message;};
fetch('/api/detail').catch(()=>{});"""
PROFILE = """<!doctype html><meta charset=utf-8><title>Synthetic profile fixture</title><pre id=identity></pre>
<script>document.querySelector('#identity').textContent='cookie='+document.cookie+'; storage='+localStorage.getItem('synthetic-owner');</script>"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if "--profile-mode" in sys.argv and self.path == "/":
            mime, body = "text/html", PROFILE.encode()
        else:
            mime, body = {
                "/": ("text/html", HOME.encode()),
                "/section/": ("text/html", b'<!doctype html><title>Section</title><h1>Section</h1><a href=/section/deep/page>Deep page</a>'),
                "/section/deep/page": ("text/html", b'<!doctype html><title>Deep page</title><h1>Three-level preserved page</h1>'),
                "/app.js": ("application/javascript", SCRIPT.encode()),
                "/ad.js": ("application/javascript", b"/* synthetic compressible advertisement fixture */" * 1300),
                "/site.css": ("text/css", b'body{font-family:system-ui;color:#182234;background:#f6f7fa}main{max-width:680px;margin:30px auto;padding:20px}button{padding:12px;margin:6px}.advert{padding:24px;background:#ffe0a8}[hidden]{display:none!important}img{width:32px;height:32px}'),
                "/api/detail": ("application/json", b'{"message":"Captured API data works offline."}'),
                "/pixel.png": ("image/png", PIXEL),
                "/favicon.ico": ("image/png", PIXEL),
            }.get(self.path, ("text/plain", b"Synthetic missing resource"))
        self.send_response(200 if self.path in {"/", "/section/", "/section/deep/page", "/app.js", "/ad.js", "/site.css", "/api/detail", "/pixel.png", "/favicon.ico"} else 404)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

ThreadingHTTPServer(("127.0.0.1", 18800), Handler).serve_forever()
