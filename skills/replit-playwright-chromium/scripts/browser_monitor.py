#!/usr/bin/env python3
"""Live monitor of the headless Chrome via page screenshots (works in headless).

Unlike CDP screencast (which captures the compositor and comes back BLACK in
headless), Page.captureScreenshot grabs the rendered page directly and works
reliably. This server polls the ACTIVE page tab on a timer and serves a
self-refreshing page on :<PORT> so the user can watch what the agent's
browser is doing from the Replit public domain.

Handles multiple tabs: always screenshots whichever tab is (a) showing a
real URL and (b) most recently active, so the monitor tracks the agent's
actual current page.
"""
import asyncio
import base64
import json
import sys
import time
import urllib.request
import websockets
from websockets.http11 import Response
from websockets.datastructures import Headers

CDP_HTTP = "http://127.0.0.1:9222"
LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
POLL_SECS = 0.8   # refresh cadence (frames per second ~= 1/POLL_SECS)

PAGE_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>Mirror</title>
<style>
  html,body{margin:0;height:100%;background:#000;overflow:hidden}
  #shot{position:fixed;inset:0;width:100vw;height:100vh;object-fit:fill;
        image-rendering:auto;background:#000}
  /* Auto-hidden overlay status bar: appears on hover or briefly on nav */
  #obscured{position:fixed;top:0;left:0;right:0;padding:5px 10px;
            background:rgba(0,0,0,.6);color:#cfc;font:12px ui-monospace,monospace;
            opacity:0;transition:opacity .2s;pointer-events:none;
            white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  body:hover #obscured{opacity:1}
  /* very subtle live indicator */
  #dot{position:fixed;bottom:8px;right:8px;width:9px;height:9px;border-radius:50%;
       background:#0f5;box-shadow:0 0 6px #0f5;opacity:.35}
  #err{position:fixed;inset:0;display:none;align-items:center;justify-content:center;
       color:#f88;font:14px monospace;text-align:center;padding:20px;background:#000}
</style></head><body>
  <img id="shot" alt="">
  <div id="obscured"></div>
  <div id="dot"></div>
  <div id="err"></div>
<script>
  const shot=document.getElementById('shot'), bar=document.getElementById('obscured');
  const err=document.getElementById('err'), dot=document.getElementById('dot');
  const proto=location.protocol==='https:'?'wss':'ws';
  let ws, live=false, url='';
  function showErr(m){err.style.display='flex';err.textContent=m;dot.style.background='#f55';dot.style.boxShadow='0 0 6px #f55'}
  function setLive(v){live=v;document.title=(v?'● live: ':'○ ') + (url||'mirror')}
  function connect(){
    ws=new WebSocket(proto+'://'+location.host+'/stream');
    ws.binaryType='arraybuffer';
    ws.onopen=()=>{err.style.display='none';setLive(live)}
    ws.onmessage=(e)=>{
      if(typeof e.data==='string'){
        const d=JSON.parse(e.data);
        if(d.type==='url'){url=d.text;bar.textContent=d.text;setLive(live)}
        if(d.type==='status' && d.text==='no page tab yet')bar.textContent='waiting for browser…';
        return;
      }
      // a frame arrived -> live
      setLive(true);
      const u=URL.createObjectURL(new Blob([e.data],{type:'image/jpeg'}));
      shot.onload=()=>{URL.revokeObjectURL(u);dot.style.opacity=.9;setTimeout(()=>dot.style.opacity=.35,150)};
      shot.src=u;
    };
    ws.onerror=()=>{ws.close()};
    ws.onclose=()=>{setLive(false);showErr('Disconnected — retrying…');setTimeout(connect,1500)};
  }
  connect();
</script></body></html>"""
PAGE_BYTES = PAGE_HTML.encode()


def _fetch_json(url, timeout=3):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def pick_target():
    """Return (ws_url, url) of the best page tab: prefers a real URL and the
    most recently touched tab. Falls back to any page."""
    tabs = _fetch_json(f"{CDP_HTTP}/json")
    pages = [t for t in tabs if t.get("type") == "page"]
    if not pages:
        return None, None
    # Rank: real URL first (so about:blank/newtab loses), then prefer the last
    # modified tab (active). `url` non-empty and title present => real page.
    def key(t):
        url = t.get("url", "")
        real = 0 if url.startswith(("http", "https")) else 1
        age = t.get("lastModified", 0) or 0
        return (real, -age)  # real first, then most recent
    pages.sort(key=key)
    return pages[0]["webSocketDebuggerUrl"], pages[0].get("url", "")


async def screenshot(ws_url):
    """Return JPEG bytes of the page, or None."""
    try:
        async with websockets.connect(ws_url, max_size=None) as c:
            n = 0
            async def cmd(m, p=None):
                nonlocal n
                n += 1
                await c.send(json.dumps({"id": n, "method": m, "params": p or {}}))
                while True:
                    r = json.loads(await c.recv())
                    if r.get("id") == n:
                        return r
            r = await cmd("Page.captureScreenshot", {"format": "jpeg", "quality": 70})
            data = (r.get("result") or {}).get("data")
            if data:
                return base64.b64decode(data)
    except Exception:
        pass
    return None


async def stream_handler(ws):
    """Continuously push fresh screenshots of the active tab."""
    last_url = None
    while True:
        try:
            ws_url, url = pick_target()
        except Exception:
            await asyncio.sleep(1)
            continue
        if url != last_url:
            last_url = url
            await ws.send(json.dumps({"type": "url", "text": url[:80]}))
        if not ws_url:
            await ws.send(json.dumps({"type": "status", "text": "no page tab yet"}))
            await asyncio.sleep(1)
            continue
        jpeg = await screenshot(ws_url)
        if jpeg:
            try:
                await ws.send(jpeg)
            except Exception:
                return  # client gone
        else:
            await ws.send(json.dumps({"type": "status", "text": "capture failed — retry"}))
        await asyncio.sleep(POLL_SECS)


async def _serve():
    async def process_request(connection, request):
        p = getattr(request, "path", None)
        if p in ("/", "/index.html"):
            return Response(200, "OK", Headers({
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": str(len(PAGE_BYTES)),
            }), PAGE_BYTES)
        if p == "/favicon.ico":
            return Response(204, "No Content", Headers({}))
        if p == "/healthz":
            return Response(200, "OK", Headers({"Content-Type": "text/plain"}), b"ok")
        return None

    async with websockets.serve(stream_handler, "0.0.0.0", LISTEN_PORT,
                                process_request=process_request,
                                max_size=None, ping_interval=20, ping_timeout=20):
        print(f"browser monitor server on :{LISTEN_PORT}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(_serve())