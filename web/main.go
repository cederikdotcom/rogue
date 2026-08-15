// Command rogue-web serves Rogue in the browser.
//
// It serves a static xterm.js page and a WebSocket endpoint. Each
// WebSocket connection starts one rogue process in its own pty and
// pipes bytes both ways. When the connection closes, the process is
// killed.
package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/creack/pty"
	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func main() {
	addr := flag.String("addr", ":80", "listen address")
	rogueBin := flag.String("rogue", "./rogue", "path to the rogue binary")
	staticDir := flag.String("static", "web/static", "directory with index.html")
	flag.Parse()

	bin, err := filepath.Abs(*rogueBin)
	if err != nil {
		log.Fatal(err)
	}

	http.Handle("/", http.FileServer(http.Dir(*staticDir)))
	http.HandleFunc("/help", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, filepath.Join(*staticDir, "help.html"))
	})
	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		serveGame(w, r, bin)
	})

	log.Printf("rogue-web: listening on %s, serving %s", *addr, bin)
	log.Fatal(http.ListenAndServe(*addr, nil))
}

func serveGame(w http.ResponseWriter, r *http.Request, bin string) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("upgrade: %v", err)
		return
	}
	defer conn.Close()

	cmd := exec.Command(bin)
	cmd.Dir = filepath.Dir(bin) // score file lives next to the binary
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")

	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 24, Cols: 80})
	if err != nil {
		conn.WriteMessage(websocket.TextMessage, []byte("cannot start rogue: "+err.Error()))
		return
	}
	log.Printf("game started for %s (pid %d)", r.RemoteAddr, cmd.Process.Pid)
	defer func() {
		// close the pty first so the reader goroutine unblocks
		ptmx.Close()
		cmd.Process.Kill()
		cmd.Wait()
		log.Printf("game ended for %s", r.RemoteAddr)
	}()

	// pty -> browser
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := ptmx.Read(buf)
			if n > 0 {
				if conn.WriteMessage(websocket.BinaryMessage, buf[:n]) != nil {
					return
				}
			}
			if err != nil {
				conn.WriteControl(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.CloseNormalClosure, "game over"),
					time.Now().Add(5*time.Second))
				return
			}
		}
	}()

	// browser -> pty
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			break
		}
		if _, err := ptmx.Write(data); err != nil {
			break
		}
	}
}
