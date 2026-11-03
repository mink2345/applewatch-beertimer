package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	_ "github.com/lib/pq"
)

type ScoreEntry struct {
	SessionPin string `json:"pin"`
	PlayerName string `json:"player_name"`
	DurationMs int    `json:"duration_ms"`
}

type SessionRoom struct {
	Pin     string
	Scores  []ScoreEntry
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
		if _, exists := h.Sessions[pin]; !exists {
			break
		}
	}

	h.Sessions[pin] = &SessionRoom{
		Pin:     pin,
		Scores:  []ScoreEntry{},
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

	h.mu.Lock()
	room, exists := h.Sessions[entry.SessionPin]
	if !exists {
		// Maak de kamer on-the-fly aan als deze nog niet bestond
		room = &SessionRoom{
			Pin:     entry.SessionPin,
			Scores:  []ScoreEntry{},
			Clients: make(map[*websocket.Conn]bool),
		}
		h.Sessions[entry.SessionPin] = room
	}

	room.Scores = append(room.Scores, entry)

	// Sorteer op snelste tijd (laagste aantal milliseconden bovenaan)
	sort.Slice(room.Scores, func(i, j int) bool {
		return room.Scores[i].DurationMs < room.Scores[j].DurationMs
	})

	scoresSnapshot := make([]ScoreEntry, len(room.Scores))
	copy(scoresSnapshot, room.Scores)

	// Push direct naar alle openstaande WebSocket-schermen in deze sessie
	for client := range room.Clients {
		err := client.WriteJSON(scoresSnapshot)
		if err != nil {
			client.Close()
			delete(room.Clients, client)
		}
	}
	h.mu.Unlock()

	// Schrijf asynchroon weg naar PostgreSQL zodat de API-call nul vertraging oploopt
	go func(e ScoreEntry) {
		if h.db != nil {
			_, err := h.db.Exec(
				"INSERT INTO drink_logs (session_pin, player_name, duration_ms) VALUES ($1, $2, $3)",
				e.SessionPin, e.PlayerName, e.DurationMs,
			)
			if err != nil {
				log.Printf("Database insert error: %v", err)
			}
		}
	}(entry)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// GET /ws?pin=1234 - WebSocket verbinding voor het Vue 3 Dashboard
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
			Scores:  []ScoreEntry{},
			Clients: make(map[*websocket.Conn]bool),
		}
		h.Sessions[pin] = room
	}
	room.Clients[conn] = true
	initialScores := room.Scores
	h.mu.Unlock()

	// Stuur direct de huidige stand bij het verbinden
	conn.WriteJSON(initialScores)

	// Houd verbinding open en ruim op bij sluiten
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

	http.HandleFunc("/api/session", hub.createSessionHandler)
	http.HandleFunc("/api/score", hub.submitScoreHandler)
	http.HandleFunc("/ws", hub.wsHandler)

	log.Println("Go Telemetry Server luistert op :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
