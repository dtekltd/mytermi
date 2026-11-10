// Package console serves the admin console (a static Next.js export) that is
// embedded into the server binary. Build it with `make console`.
package console

import (
	"embed"
	"io/fs"
	"net/http"
	"path"
	"strings"
)

//go:embed all:dist
var dist embed.FS

// Handler serves the console under /console/.
func Handler() http.Handler {
	root, _ := fs.Sub(dist, "dist")
	files := http.FileServer(http.FS(root))
	if _, err := fs.Stat(root, "index.html"); err != nil {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(notBuilt))
		})
	}
	return http.StripPrefix("/console", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := path.Clean("/" + r.URL.Path)
		// Next.js export (trailingSlash) writes page/index.html; map clean URLs onto it.
		name := strings.TrimPrefix(p, "/")
		if name == "" {
			name = "index.html"
		}
		if st, err := fs.Stat(root, name); err != nil || st.IsDir() {
			if _, err := fs.Stat(root, path.Join(name, "index.html")); err == nil {
				if !strings.HasSuffix(r.URL.Path, "/") {
					http.Redirect(w, r, "/console"+p+"/", http.StatusMovedPermanently)
					return
				}
			} else if _, err := fs.Stat(root, name+".html"); err == nil {
				r.URL.Path = p + ".html"
			} else {
				r.URL.Path = "/" // client-side route: let the app handle it
			}
		}
		if strings.HasPrefix(p, "/_next/static/") {
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		} else {
			w.Header().Set("Cache-Control", "no-cache")
		}
		files.ServeHTTP(w, r)
	}))
}

const notBuilt = `<!doctype html><meta charset="utf-8"><title>MyTermi console</title>
<p style="font-family:sans-serif;padding:2rem">Console chưa được build vào binary này.
Chạy <code>make build</code> trong thư mục <code>server/</code> (hoặc dùng Docker image).</p>`
