#!/usr/bin/env python3
"""
Tornado-based server that:
  1. Serves the existing Flask app (handles /, /api/*, papaya/, novnc/, etc.) via WSGI
  2. Reverse-proxies Jupyter at /jupyter/* (HTTP + WebSocket)
This lets us expose Jupyter through the same port 8080 that Flask already uses,
bypassing frontier's firewall restrictions on other ports.

Run with the survivehr conda env's Python:
  /Data0/swangek_data/conda_envs/survivehr/bin/python proxy_server.py 8080
"""
import os
import sys
import json
import asyncio

import tornado.web
import tornado.wsgi
import tornado.httpclient
import tornado.websocket
import tornado.httpserver
import tornado.ioloop

# Import the existing Flask app
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from server import app as flask_app

JUPYTER_BACKEND = "http://localhost:6081"  # Local Jupyter tunnel target


def get_jupyter_token():
    """Read the current Jupyter token from state file."""
    state_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.jupyter_state.json')
    try:
        with open(state_file) as f:
            return json.load(f).get('token', '')
    except Exception:
        return ''


class JupyterHTTPProxy(tornado.web.RequestHandler):
    """Forward HTTP requests for /jupyter/* to Jupyter backend."""
    SUPPORTED_METHODS = ('GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS', 'HEAD')

    async def _proxy(self):
        path = self.request.uri  # includes /jupyter/...
        url = JUPYTER_BACKEND + path
        # Pass through headers (except hop-by-hop)
        headers = {k: v for k, v in self.request.headers.get_all()
                   if k.lower() not in ('host', 'connection', 'content-length')}
        try:
            client = tornado.httpclient.AsyncHTTPClient()
            resp = await client.fetch(
                url,
                method=self.request.method,
                headers=headers,
                body=self.request.body if self.request.method in ('POST', 'PUT', 'PATCH') else None,
                allow_nonstandard_methods=True,
                follow_redirects=False,
                request_timeout=300,
                raise_error=False,
            )
            self.set_status(resp.code)
            self.clear_header('Server')
            self.clear_header('Content-Type')
            for k, v in resp.headers.get_all():
                if k.lower() in ('content-length', 'connection', 'transfer-encoding',
                                  'cache-control', 'expires', 'pragma', 'etag', 'last-modified'):
                    continue  # Strip cache headers so browser always refetches
                if k.lower() in ('content-type', 'server', 'date'):
                    self.set_header(k, v)
                else:
                    self.add_header(k, v)
            # Force browser to always revalidate — busts stale cache from earlier bug
            self.set_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
            self.set_header('Pragma', 'no-cache')
            if resp.body:
                self.write(resp.body)
        except Exception as e:
            self.set_status(502)
            self.write(f"Proxy error: {e}".encode())

    async def get(self): await self._proxy()
    async def post(self): await self._proxy()
    async def put(self): await self._proxy()
    async def delete(self): await self._proxy()
    async def patch(self): await self._proxy()
    async def options(self): await self._proxy()
    async def head(self): await self._proxy()


class WebsockifyWSProxy(tornado.websocket.WebSocketHandler):
    """Proxy /websockify → localhost:6080/websockify for VNC."""
    def check_origin(self, origin):
        return True

    def select_subprotocol(self, subprotocols):
        # Pass through 'binary' subprotocol used by noVNC
        if subprotocols:
            return subprotocols[0]
        return None

    async def open(self):
        backend_url = "ws://localhost:6080/websockify"
        try:
            self.backend = await tornado.websocket.websocket_connect(
                backend_url,
                subprotocols=['binary'],
            )
        except Exception as e:
            self.close(code=1011, reason=f"websockify connect failed: {e}")
            return
        async def read_backend():
            try:
                while True:
                    msg = await self.backend.read_message()
                    if msg is None:
                        self.close()
                        return
                    await self.write_message(msg, binary=isinstance(msg, bytes))
            except Exception:
                self.close()
        asyncio.create_task(read_backend())

    async def on_message(self, message):
        if getattr(self, 'backend', None) is None:
            return
        try:
            await self.backend.write_message(message, binary=isinstance(message, bytes))
        except Exception:
            self.close()

    def on_close(self):
        if getattr(self, 'backend', None) is not None:
            self.backend.close()


class JupyterWSProxy(tornado.websocket.WebSocketHandler):
    """Bidirectional WebSocket proxy for Jupyter kernel channels."""
    def check_origin(self, origin):
        return True

    async def open(self):
        backend_url = ("ws://localhost:6081" + self.request.uri)
        try:
            # Forward subprotocols if any
            subprotocol = None
            headers = {k: v for k, v in self.request.headers.get_all()
                       if k.lower() not in ('host', 'upgrade', 'connection', 'sec-websocket-key',
                                            'sec-websocket-version', 'sec-websocket-extensions',
                                            'sec-websocket-protocol')}
            self.backend = await tornado.websocket.websocket_connect(
                tornado.httpclient.HTTPRequest(backend_url, headers=headers),
                subprotocols=self.selected_subprotocol() and [self.selected_subprotocol()] or None,
            )
        except Exception as e:
            self.close(code=1011, reason=f"backend connect failed: {e}")
            return

        # Reader: backend → client
        async def read_backend():
            try:
                while True:
                    msg = await self.backend.read_message()
                    if msg is None:
                        self.close()
                        return
                    await self.write_message(msg, binary=isinstance(msg, bytes))
            except Exception:
                self.close()
        asyncio.create_task(read_backend())

    async def on_message(self, message):
        if getattr(self, 'backend', None) is None:
            return
        try:
            await self.backend.write_message(message, binary=isinstance(message, bytes))
        except Exception:
            self.close()

    def on_close(self):
        if getattr(self, 'backend', None) is not None:
            self.backend.close()


def make_app():
    wsgi_container = tornado.wsgi.WSGIContainer(flask_app)
    return tornado.web.Application([
        # VNC WebSocket proxy: /websockify → localhost:6080
        (r"/websockify", WebsockifyWSProxy),
        # WebSocket proxy — must match BEFORE generic /jlab/ HTTP handler
        (r"/jlab/api/kernels/.*/channels.*", JupyterWSProxy),
        (r"/jlab/api/kernels/.*", JupyterHTTPProxy),
        (r"/jlab/api/events/subscribe", JupyterWSProxy),
        (r"/jlab/api/yjs.*", JupyterWSProxy),
        (r"/jlab/terminals/websocket/.*", JupyterWSProxy),
        # All other /jlab/* → HTTP proxy
        (r"/jlab/.*", JupyterHTTPProxy),
        (r"/jlab", JupyterHTTPProxy),
        # Everything else → Flask via WSGI
        (r".*", tornado.web.FallbackHandler, dict(fallback=wsgi_container)),
    ], websocket_max_message_size=64 * 1024 * 1024)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    app = make_app()
    server = tornado.httpserver.HTTPServer(app, max_buffer_size=64 * 1024 * 1024)
    server.listen(port)
    print(f"Tornado proxy server listening on :{port}")
    print(f"  Flask routes: /, /api/*, /papaya/*, /novnc/*")
    print(f"  Jupyter proxy: /jupyter/* → {JUPYTER_BACKEND}")
    tornado.ioloop.IOLoop.current().start()


if __name__ == '__main__':
    main()
