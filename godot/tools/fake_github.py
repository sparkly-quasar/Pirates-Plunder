# A stand-in for GitHub's releases, for the update tests: one release, TAG,
# whose files are whatever is in SITE.
#   /api/latest                  the API's latest release (asks for our User-Agent)
#   /api/limited                 the API with its hourly limit used up (403)
#   /releases/latest             302 to /releases/tag/TAG, as github.com does
#   /releases/download/TAG/NAME  302 to /files/NAME, as GitHub's downloads do
# Usage: python3 fake_github.py PORT SITE TAG
import http.server, json, os, sys
port, site, tag = int(sys.argv[1]), sys.argv[2], sys.argv[3]
here = "http://127.0.0.1:%d" % port

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=site, **k)

    def log_message(self, *a):
        pass

    def redirect(self, to):
        self.send_response(302)
        self.send_header("Location", to)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path == "/api/latest":
            if not self.headers.get("User-Agent", "").startswith("PiratesPlunder/"):
                self.send_error(403)
                return
            names = sorted(n for n in os.listdir(site) if os.path.isfile(os.path.join(site, n)) and not n.endswith(".py"))
            body = json.dumps({"tag_name": tag, "html_url": here + "/releases/tag/" + tag,
                "assets": [{"name": n, "browser_download_url": "%s/releases/download/%s/%s" % (here, tag, n)} for n in names]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/api/limited":
            self.send_error(403)
            return
        if self.path == "/releases/latest":
            self.redirect(here + "/releases/tag/" + tag)
            return
        if self.path.startswith("/releases/download/%s/" % tag):
            self.redirect("/files/" + self.path.rsplit("/", 1)[1])
            return
        if self.path.startswith("/files/"):
            self.path = "/" + self.path[len("/files/"):]
            return super().do_GET()
        self.send_error(404)

http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
