package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

var worldPorts = map[int]int{
	1: 19082,
	2: 19083,
	3: 19084,
}

type config struct {
	host            string
	port            int
	key             string
	godotPath       string
	projectRoot     string
	logRoot         string
	nakamaHost      string
	nakamaPort      int
	nakamaServerKey string
	nakamaHTTPKey   string
	defaultIdle     time.Duration
}

type worldRecord struct {
	WorldID     int    `json:"world_id"`
	State       string `json:"state"`
	Port        int    `json:"port"`
	URL         string `json:"url"`
	PlayerCount int    `json:"player_count"`
	PID         int    `json:"pid,omitempty"`

	cmd          *exec.Cmd
	idleShutdown time.Duration
	startedAt    time.Time
	lastHeartbeat time.Time
	lastEmptyAt  time.Time
}

type orchestrator struct {
	cfg    config
	mu     sync.Mutex
	worlds map[int]*worldRecord
}

type ensureRequest struct {
	WorldID             int `json:"world_id"`
	IdleShutdownSeconds int `json:"idle_shutdown_seconds"`
}

type heartbeatRequest struct {
	WorldID     int `json:"world_id"`
	PlayerCount int `json:"player_count"`
}

func main() {
	log.SetOutput(os.Stdout)
	cfg := parseConfig()
	o := &orchestrator{
		cfg:    cfg,
		worlds: map[int]*worldRecord{},
	}

	go o.reapIdleWorlds()

	mux := http.NewServeMux()
	mux.HandleFunc("POST /worlds/ensure", o.handleEnsure)
	mux.HandleFunc("POST /worlds/heartbeat", o.handleHeartbeat)
	mux.HandleFunc("GET /worlds", o.handleList)
	mux.HandleFunc("POST /worlds/", o.handleWorldAction)

	addr := fmt.Sprintf("%s:%d", cfg.host, cfg.port)
	log.Printf("ORCHESTRATOR_READY url=http://%s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func parseConfig() config {
	var cfg config
	flag.StringVar(&cfg.host, "host", "127.0.0.1", "HTTP listen host")
	flag.IntVar(&cfg.port, "port", 19100, "HTTP listen port")
	flag.StringVar(&cfg.key, "key", "localdev-secret", "shared private API key")
	flag.StringVar(&cfg.godotPath, "godot", "", "Godot executable path")
	flag.StringVar(&cfg.projectRoot, "project-root", ".", "Godot project root")
	flag.StringVar(&cfg.logRoot, "log-root", ".logs/orchestrator", "world process log directory")
	flag.StringVar(&cfg.nakamaHost, "nakama-host", "127.0.0.1", "Nakama host for world ticket validation")
	flag.IntVar(&cfg.nakamaPort, "nakama-port", 7350, "Nakama HTTP port")
	flag.StringVar(&cfg.nakamaServerKey, "nakama-server-key", "defaultkey", "Nakama server key")
	flag.StringVar(&cfg.nakamaHTTPKey, "nakama-http-key", "defaulthttpkey", "Nakama runtime HTTP key")
	defaultIdleSeconds := flag.Int("idle-shutdown-seconds", 300, "default idle shutdown seconds")
	flag.Parse()

	cfg.defaultIdle = time.Duration(*defaultIdleSeconds) * time.Second
	if cfg.godotPath == "" {
		log.Fatal("--godot is required")
	}

	absRoot, err := filepath.Abs(cfg.projectRoot)
	if err != nil {
		log.Fatalf("resolve project root: %v", err)
	}
	cfg.projectRoot = absRoot
	return cfg
}

func (o *orchestrator) handleEnsure(w http.ResponseWriter, r *http.Request) {
	if !o.authorized(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	var req ensureRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}
	world, err := o.ensureWorld(req)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":    true,
		"world": publicWorld(world),
	})
}

func (o *orchestrator) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	if !o.authorized(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	var req heartbeatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	o.mu.Lock()
	defer o.mu.Unlock()
	world, ok := o.worlds[req.WorldID]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "unknown world"})
		return
	}
	world.State = "ready"
	world.PlayerCount = req.PlayerCount
	world.lastHeartbeat = time.Now()
	if req.PlayerCount > 0 {
		world.lastEmptyAt = time.Time{}
	} else if world.lastEmptyAt.IsZero() {
		world.lastEmptyAt = time.Now()
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (o *orchestrator) handleList(w http.ResponseWriter, r *http.Request) {
	if !o.authorized(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}

	o.mu.Lock()
	worlds := make([]map[string]any, 0, len(o.worlds))
	for _, world := range o.worlds {
		worlds = append(worlds, publicWorld(world))
	}
	o.mu.Unlock()

	writeJSON(w, http.StatusOK, map[string]any{"worlds": worlds})
}

func (o *orchestrator) handleWorldAction(w http.ResponseWriter, r *http.Request) {
	if !o.authorized(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return
	}
	if !strings.HasSuffix(r.URL.Path, "/stop") {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}

	raw := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/worlds/"), "/stop")
	worldID, err := strconv.Atoi(raw)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid world id"})
		return
	}
	o.stopWorld(worldID, "api")
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (o *orchestrator) authorized(r *http.Request) bool {
	return r.Header.Get("X-Orchestrator-Key") == o.cfg.key
}

func (o *orchestrator) ensureWorld(req ensureRequest) (*worldRecord, error) {
	port, ok := worldPorts[req.WorldID]
	if !ok {
		return nil, errors.New("unknown world_id")
	}

	o.mu.Lock()
	existing := o.worlds[req.WorldID]
	if existing != nil {
		defer o.mu.Unlock()
		return existing, nil
	}
	o.mu.Unlock()

	idle := o.cfg.defaultIdle
	if req.IdleShutdownSeconds > 0 {
		idle = time.Duration(req.IdleShutdownSeconds) * time.Second
	}

	world, err := o.startWorld(req.WorldID, port, idle)
	if err != nil {
		return nil, err
	}

	o.mu.Lock()
	o.worlds[req.WorldID] = world
	o.mu.Unlock()
	return world, nil
}

func (o *orchestrator) startWorld(worldID int, port int, idle time.Duration) (*worldRecord, error) {
	if err := os.MkdirAll(o.cfg.logRoot, 0o755); err != nil {
		return nil, fmt.Errorf("create log root: %w", err)
	}

	args := []string{
		"--headless",
		"--path", o.cfg.projectRoot,
		"--",
		"--role", "world",
		"--world", strconv.Itoa(worldID),
		"--port", strconv.Itoa(port),
		"--nakama-host", o.cfg.nakamaHost,
		"--nakama-port", strconv.Itoa(o.cfg.nakamaPort),
		"--nakama-server-key", o.cfg.nakamaServerKey,
		"--nakama-http-key", o.cfg.nakamaHTTPKey,
		"--orchestrator-url", fmt.Sprintf("http://%s:%d", o.cfg.host, o.cfg.port),
		"--orchestrator-key", o.cfg.key,
	}

	cmd := exec.Command(o.cfg.godotPath, args...)
	cmd.Dir = o.cfg.projectRoot

	stdoutPath := filepath.Join(o.cfg.logRoot, fmt.Sprintf("world_%d.out.log", worldID))
	stderrPath := filepath.Join(o.cfg.logRoot, fmt.Sprintf("world_%d.err.log", worldID))
	stdout, err := os.Create(stdoutPath)
	if err != nil {
		return nil, fmt.Errorf("create stdout log: %w", err)
	}
	stderr, err := os.Create(stderrPath)
	if err != nil {
		stdout.Close()
		return nil, fmt.Errorf("create stderr log: %w", err)
	}
	cmd.Stdout = stdout
	cmd.Stderr = stderr

	if err := cmd.Start(); err != nil {
		stdout.Close()
		stderr.Close()
		return nil, fmt.Errorf("start world: %w", err)
	}

	world := &worldRecord{
		WorldID:      worldID,
		State:        "starting",
		Port:         port,
		URL:          fmt.Sprintf("ws://127.0.0.1:%d", port),
		PID:          cmd.Process.Pid,
		cmd:          cmd,
		idleShutdown: idle,
		startedAt:    time.Now(),
		lastEmptyAt:  time.Now(),
	}

	log.Printf("ORCHESTRATOR_WORLD_STARTED id=%d pid=%d port=%d", worldID, world.PID, port)
	go o.waitWorld(world, stdout, stderr)
	return world, nil
}

func (o *orchestrator) waitWorld(world *worldRecord, stdout *os.File, stderr *os.File) {
	err := world.cmd.Wait()
	stdout.Close()
	stderr.Close()

	o.mu.Lock()
	if current := o.worlds[world.WorldID]; current == world {
		delete(o.worlds, world.WorldID)
	}
	o.mu.Unlock()

	if err != nil {
		log.Printf("ORCHESTRATOR_WORLD_EXITED id=%d pid=%d err=%v", world.WorldID, world.PID, err)
	} else {
		log.Printf("ORCHESTRATOR_WORLD_EXITED id=%d pid=%d", world.WorldID, world.PID)
	}
}

func (o *orchestrator) stopWorld(worldID int, reason string) {
	o.mu.Lock()
	world := o.worlds[worldID]
	if world == nil {
		o.mu.Unlock()
		return
	}
	delete(o.worlds, worldID)
	o.mu.Unlock()

	if world.cmd != nil && world.cmd.Process != nil {
		_ = world.cmd.Process.Kill()
	}
	log.Printf("ORCHESTRATOR_WORLD_STOPPED id=%d pid=%d reason=%s", worldID, world.PID, reason)
}

func (o *orchestrator) reapIdleWorlds() {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		var stopIDs []int

		o.mu.Lock()
		for id, world := range o.worlds {
			if world.PlayerCount > 0 || world.lastEmptyAt.IsZero() {
				continue
			}
			if now.Sub(world.lastEmptyAt) >= world.idleShutdown {
				stopIDs = append(stopIDs, id)
			}
		}
		o.mu.Unlock()

		for _, id := range stopIDs {
			o.stopWorld(id, "idle")
		}
	}
}

func publicWorld(world *worldRecord) map[string]any {
	return map[string]any{
		"world_id":     world.WorldID,
		"state":        world.State,
		"port":         world.Port,
		"url":          world.URL,
		"player_count": world.PlayerCount,
		"pid":          world.PID,
	}
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("write json response: %v", err)
	}
}
