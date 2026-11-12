package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	_ "github.com/lib/pq"
)

type ScoreEntry struct {
	SessionPin string `json:"pin"`
	PlayerName string `json:"player_name"`
	DurationMs int    `json:"duration_ms"`
	Attempts   int    `json:"attempts"`
}

type SessionRoom struct {
	Pin     string
	Clients map[*websocket.Conn]bool
}

type Hub struct {
	mu       sync.RWMutex
	Sessions map[string]*SessionRoom
	db       *sql.DB
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func NewHub(db *sql.DB) *Hub {
	return &Hub{
		Sessions: make(map[string]*SessionRoom),
		db:       db,
	}
}

// Haalt de top 25 van een kamer op uit PostgreSQL (alleen snelste tijd per naam + aantal pogingen)
func (h *Hub) getLeaderboard(pin string) []ScoreEntry {
	scores := []ScoreEntry{}
	if h.db == nil {
		return scores
	}

	rows, err := h.db.Query(`
		SELECT player_name, MIN(duration_ms) as best_time, COUNT(*) as attempts
		FROM drink_logs
		WHERE session_pin = $1
		GROUP BY player_name
		ORDER BY best_time ASC
		LIMIT 25
	`, pin)
	if err != nil {
		log.Printf("DB query fout voor pin %s: %v", pin, err)
		return scores
	}
	defer rows.Close()

	for rows.Next() {
		var s ScoreEntry
		s.SessionPin = pin
		if err := rows.Scan(&s.PlayerName, &s.DurationMs, &s.Attempts); err == nil {
			scores = append(scores, s)
		}
	}
	return scores
}

// Achtergrond-worker die elke 24 uur logs ouder dan 30 dagen verwijdert
func (h *Hub) startCleanupWorker() {
	ticker := time.NewTicker(24 * time.Hour)
	go func() {
		for range ticker.C {
			if h.db != nil {
				res, err := h.db.Exec("DELETE FROM drink_logs WHERE created_at < NOW() - INTERVAL '30 days'")
				if err == nil {
					affected, _ := res.RowsAffected()
					log.Printf("Cleanup voltooid: %d oude scores verwijderd", affected)
				}
			}
		}
	}()
}

// POST /api/session - Genereert een nieuwe 4-cijferige sessie-PIN
func (h *Hub) createSessionHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	var pin string
	for {
		pin = fmt.Sprintf("%04d", rand.Intn(10000))
		if _, exists := h.Sessions[pin]; !exists && pin != "8888" {
			break
		}
	}

	h.Sessions[pin] = &SessionRoom{
		Pin:     pin,
		Clients: make(map[*websocket.Conn]bool),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"pin": pin})
}

// POST /api/score - Ontvangt sensordata van de Apple Watch
func (h *Hub) submitScoreHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var entry ScoreEntry
	if err := json.NewDecoder(r.Body).Decode(&entry); err != nil {
		http.Error(w, "Invalid payload", http.StatusBadRequest)
		return
	}

	entry.PlayerName = strings.TrimSpace(entry.PlayerName)
	if entry.PlayerName == "" || len(entry.SessionPin) != 4 {
		http.Error(w, "Naam en 4-cijferige PIN zijn verplicht", http.StatusBadRequest)
		return
	}

	// Anti-cheat: weiger fysiek onmogelijke tijden onder de 0.8 seconden
	if entry.DurationMs < 800 {
		http.Error(w, "Tijd ongeldig (onder 0.8s)", http.StatusBadRequest)
		return
	}

	// 1. Sla direct op in PostgreSQL
	if h.db != nil {
		_, err := h.db.Exec(
			"INSERT INTO drink_logs (session_pin, player_name, duration_ms) VALUES ($1, $2, $3)",
			entry.SessionPin, entry.PlayerName, entry.DurationMs,
		)
		if err != nil {
			log.Printf("Database insert error: %v", err)
			http.Error(w, "Database fout", http.StatusInternalServerError)
			return
		}
	}

	// 2. Haal de bijgewerkte lijst op en push naar alle verbonden WebSockets
	updatedLeaderboard := h.getLeaderboard(entry.SessionPin)

	h.mu.Lock()
	room, exists := h.Sessions[entry.SessionPin]
	if !exists {
		room = &SessionRoom{
			Pin:     entry.SessionPin,
			Clients: make(map[*websocket.Conn]bool),
		}
		h.Sessions[entry.SessionPin] = room
	}

	for client := range room.Clients {
		if err := client.WriteJSON(updatedLeaderboard); err != nil {
			client.Close()
			delete(room.Clients, client)
		}
	}
	h.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(updatedLeaderboard)
}

// GET /ws?pin=1234 - WebSocket verbinding voor live updates op de Watch
func (h *Hub) wsHandler(w http.ResponseWriter, r *http.Request) {
	pin := r.URL.Query().Get("pin")
	if len(pin) != 4 {
		http.Error(w, "Geldige 4-cijferige PIN vereist", http.StatusBadRequest)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("WebSocket upgrade fout: %v", err)
		return
	}

	h.mu.Lock()
	room, exists := h.Sessions[pin]
	if !exists {
		room = &SessionRoom{
			Pin:     pin,
			Clients: make(map[*websocket.Conn]bool),
		}
		h.Sessions[pin] = room
	}
	room.Clients[conn] = true
	h.mu.Unlock()

	// Stuur direct de huidige stand uit PostgreSQL bij het verbinden
	initialScores := h.getLeaderboard(pin)
	conn.WriteJSON(initialScores)

	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			h.mu.Lock()
			delete(room.Clients, conn)
			h.mu.Unlock()
			conn.Close()
			break
		}
	}
}

func main() {
	rand.Seed(time.Now().UnixNano())

	dbURL := os.Getenv("DATABASE_URL")
	db, err := sql.Open("postgres", dbURL)
	if err != nil {
		log.Printf("Waarschuwing: kan DB niet openen: %v", err)
	}

	hub := NewHub(db)
	hub.startCleanupWorker()

	http.HandleFunc("/api/session", hub.createSessionHandler)
	http.HandleFunc("/api/score", hub.submitScoreHandler)
	http.HandleFunc("/ws", hub.wsHandler)

	log.Println("Go Telemetry Server luistert op :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
