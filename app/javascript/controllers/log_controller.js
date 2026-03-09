import { Controller } from "@hotwired/stimulus"

// Manages the deployment log terminal.
//
// Features:
//   - Auto-scrolls to the bottom as new lines arrive via Turbo Streams
//   - Pauses auto-scroll when the user manually scrolls up
//   - Resumes auto-scroll when the user scrolls back to the bottom
//   - Updates the line count in the toolbar
//   - Tracks elapsed time while the deployment is in progress
//
// Usage:
//   <div data-controller="log"
//        data-log-running-value="true"
//        data-log-started-at-value="2024-01-01T00:00:00Z">
//     <span data-log-target="lineCount"></span>
//     <span data-log-target="elapsed"></span>
//     <div data-log-target="container">…log lines…</div>
//   </div>

export default class extends Controller {
  static targets = ["container", "lineCount", "elapsed"]
  static values  = { running: Boolean, startedAt: String }

  connect() {
    this._autoScroll = true
    this._observer   = null
    this._timer      = null

    this._attachScrollListener()
    this._attachMutationObserver()
    this._scrollToBottom()
    this._updateLineCount()

    if (this.runningValue && this.startedAtValue) {
      this._startElapsedTimer()
    }
  }

  disconnect() {
    this._observer?.disconnect()
    clearInterval(this._timer)
    this.containerTarget.removeEventListener("scroll", this._onScroll)
  }

  // ── Private ──────────────────────────────────────────────────────── //

  _attachScrollListener() {
    this._onScroll = () => {
      const el = this.containerTarget
      const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40
      this._autoScroll = atBottom
    }
    this.containerTarget.addEventListener("scroll", this._onScroll, { passive: true })
  }

  _attachMutationObserver() {
    this._observer = new MutationObserver(() => {
      this._updateLineCount()
      if (this._autoScroll) this._scrollToBottom()
    })
    this._observer.observe(this.containerTarget, { childList: true, subtree: false })
  }

  _scrollToBottom() {
    const el = this.containerTarget
    el.scrollTop = el.scrollHeight
  }

  _updateLineCount() {
    if (!this.hasLineCountTarget) return
    const count = this.containerTarget.querySelectorAll("[data-log-line]").length
    this.lineCountTarget.textContent = `${count} line${count === 1 ? "" : "s"}`
  }

  _startElapsedTimer() {
    if (!this.hasElapsedTarget) return
    const start = new Date(this.startedAtValue)
    this._timer = setInterval(() => {
      const secs = Math.floor((Date.now() - start) / 1000)
      const m = Math.floor(secs / 60)
      const s = secs % 60
      this.elapsedTarget.textContent = m > 0
        ? `${m}m ${String(s).padStart(2, "0")}s`
        : `${s}s`
    }, 1000)
  }
}
