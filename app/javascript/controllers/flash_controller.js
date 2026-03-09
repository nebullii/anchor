import { Controller } from "@hotwired/stimulus"

// Auto-dismisses flash messages after a delay.
//
// Usage:
//   <div data-controller="flash" data-flash-delay-value="4000">…</div>

export default class extends Controller {
  static values = { delay: { type: Number, default: 4000 } }

  connect() {
    this._timeout = setTimeout(() => this._dismiss(), this.delayValue)
  }

  disconnect() {
    clearTimeout(this._timeout)
  }

  dismiss() {
    this._dismiss()
  }

  // ── Private ──────────────────────────────────────────────────────── //

  _dismiss() {
    this.element.style.transition = "opacity 0.3s ease"
    this.element.style.opacity    = "0"
    setTimeout(() => this.element.remove(), 350)
  }
}
