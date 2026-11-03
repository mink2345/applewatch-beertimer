<script setup>
import { ref, onUnmounted } from 'vue'

const pinInput = ref('')
const activePin = ref(null)
const leaderboard = ref([])
const wsConnected = ref(false)
let socket = null

const createNewSession = async () => {
  const res = await fetch('/api/session', { method: 'POST' })
  const data = await res.json()
  pinInput.value = data.pin
  connectToSession()
}

const connectToSession = () => {
  if (pinInput.value.length !== 4) return
  if (socket) socket.close()

  activePin.value = pinInput.value
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  socket = new WebSocket(`${protocol}//${window.location.host}/ws?pin=${activePin.value}`)

  socket.onopen = () => {
    wsConnected.value = true
  }

  socket.onmessage = (event) => {
    leaderboard.value = JSON.parse(event.data) || []
  }

  socket.onclose = () => {
    wsConnected.value = false
  }
}

const leaveSession = () => {
  if (socket) socket.close()
  activePin.value = null
  leaderboard.value = []
}

onUnmounted(() => {
  if (socket) socket.close()
})
</script>

<template>
  <main style="max-width: 720px; margin: 60px auto; padding: 0 20px; text-align: center;">
    <h1>IoT Telemetry Leaderboard</h1>

    <!-- Landingspagina: Sessie kiezen of aanmaken -->
    <div v-if="!activePin" style="background: #1e293b; padding: 40px; border-radius: 16px;">
      <p style="font-size: 1.1rem; color: #94a3b8;">Voer een 4-cijferige sessie-PIN in of start een nieuwe kamer:</p>
      <div style="display: flex; gap: 12px; justify-content: center; margin-top: 20px;">
        <input
          v-model="pinInput"
          maxlength="4"
          placeholder="0000"
          style="font-size: 2rem; width: 140px; text-align: center; border-radius: 8px; border: 2px solid #334155; background: #0f172a; color: white; padding: 8px;"
        />
        <button
          @click="connectToSession"
          style="font-size: 1.1rem; padding: 0 24px; border-radius: 8px; border: none; background: #3b82f6; color: white; cursor: pointer; font-weight: bold;"
        >
          Open Bord
        </button>
      </div>
      <div style="margin-top: 28px;">
        <button
          @click="createNewSession"
          style="background: transparent; border: 1px solid #475569; color: #cbd5e1; padding: 10px 20px; border-radius: 8px; cursor: pointer;"
        >
          + Genereer Nieuwe Sessie-PIN
        </button>
      </div>
    </div>

    <!-- Live Klassement Scherm -->
    <div v-else>
      <div style="background: #1e293b; padding: 24px; border-radius: 16px; margin-bottom: 32px; display: flex; justify-content: space-between; align-items: center;">
        <div style="text-align: left;">
          <span style="color: #94a3b8; font-size: 0.9rem; text-transform: uppercase;">Actieve Sessie-PIN</span>
          <div style="font-size: 3rem; font-weight: 800; letter-spacing: 6px; color: #38bdf8;">{{ activePin }}</div>
        </div>
        <div>
          <span :style="{ color: wsConnected ? '#4ade80' : '#f87171', display: 'block', marginBottom: '8px' }">
            ● {{ wsConnected ? 'Live verbonden' : 'Verbinding verbroken' }}
          </span>
          <button @click="leaveSession" style="background: #334155; border: none; color: white; padding: 8px 16px; border-radius: 6px; cursor: pointer;">
            Sluit Sessie
          </button>
        </div>
      </div>

      <div v-if="leaderboard.length === 0" style="padding: 60px; border: 2px dashed #334155; border-radius: 16px; color: #64748b;">
        Wachten op de eerste polsbeweging vanaf een Apple Watch...
      </div>

      <div v-else style="display: flex; flex-direction: column; gap: 12px;">
        <div
          v-for="(entry, index) in leaderboard"
          :key="index"
          style="display: flex; justify-content: space-between; align-items: center; background: #1e293b; padding: 18px 24px; border-radius: 12px; border-left: 6px solid #38bdf8;"
        >
          <div style="display: flex; align-items: center; gap: 16px;">
            <span style="font-size: 1.5rem; font-weight: bold; width: 36px; color: #94a3b8;">#{{ index + 1 }}</span>
            <span style="font-size: 1.3rem; font-weight: 600;">{{ entry.player_name }}</span>
          </div>
          <div style="font-size: 1.6rem; font-weight: 800; color: #4ade80;">
            {{ (entry.duration_ms / 1000).toFixed(2) }}s
          </div>
        </div>
      </div>
    </div>
  </main>
</template>