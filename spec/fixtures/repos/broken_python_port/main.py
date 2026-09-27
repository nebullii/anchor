from http.server import HTTPServer, SimpleHTTPRequestHandler

HTTPServer(("localhost", 9999), SimpleHTTPRequestHandler).serve_forever()
