"""端到端測試用本地 WebDAV 伺服器(wsgidav)。

啟動:python dav_test_server.py <root_dir> <port>
終止:直接 Ctrl-C 或由外部管理工作。
"""
import sys
from wsgidav.wsgidav_app import WsgiDAVApp
from wsgidav.fs_dav_provider import FilesystemProvider
from cheroot import wsgi

root = sys.argv[1]
port = int(sys.argv[2])

provider = FilesystemProvider(root)
app = WsgiDAVApp({
    "provider_mapping": {"/": provider},
    "simple_dc": {"user_mapping": {"*": {"tester": {"password": "testpw"}}}},
    "verbose": 1,
    "dir_browser": {"enable": True},
    "http_authenticator": {"accept_basic": True, "accept_digest": True, "default_to_digest": False},
})

server = wsgi.Server(("127.0.0.1", port), app)
print(f"DAV server ready on http://127.0.0.1:{port}", flush=True)
server.start()
