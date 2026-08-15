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
	"regexp"
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
	saveDir := flag.String("saves", "", "directory for per-player save files (default: saves/ next to the binary)")
	flag.Parse()

	bin, err := filepath.Abs(*rogueBin)
	if err != nil {
		log.Fatal(err)
	}
	if *saveDir == "" {
		*saveDir = filepath.Join(filepath.Dir(bin), "saves")
	}
	if err := os.MkdirAll(*saveDir, 0o755); err != nil {
		log.Fatal(err)
	}

	http.Handle("/", http.FileServer(http.Dir(*staticDir)))
	http.HandleFunc("/help", func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, filepath.Join(*staticDir, "help.html"))
	})
	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		serveGame(w, r, bin, *saveDir)
	})

	log.Printf("rogue-web: listening on %s, serving %s", *addr, bin)
	log.Fatal(http.ListenAndServe(*addr, nil))
}

var playerID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

func serveGame(w http.ResponseWriter, r *http.Request, bin, saveDir string) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("upgrade: %v", err)
		return
	}
	defer conn.Close()

	// Per-player save file, keyed by the id the browser stores in
	// localStorage. S saves there; on reconnect the game restores
	// from it (rogue deletes the file when it restores).
	var args []string
	env := append(os.Environ(), "TERM=xterm-256color")
	if id := r.URL.Query().Get("p"); playerID.MatchString(id) {
		save := filepath.Join(saveDir, id+".save")
		opts := "file=" + save
		if name := r.URL.Query().Get("name"); name != "" && len(name) <= 32 {
			opts += ";name=" + name
		}
		env = append(env, "ROGUEOPTS="+opts)
		if _, err := os.Stat(save); err == nil {
			args = append(args, save)
		}
	}

	cmd := exec.Command(bin, args...)
	cmd.Dir = filepath.Dir(bin) // score file lives next to the binary
	cmd.Env = env

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
