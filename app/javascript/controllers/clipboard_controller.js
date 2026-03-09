import { Controller } from "@hotwired/stimulus"

// Copies a value to the clipboard and shows brief feedback.
//
// Usage:
//   <div data-controller="clipboard" data-clipboard-value="https://my-app.run.app">
//     <button data-action="clipboard#copy" data-clipboard-target="button">
//       Copy
//     </button>
//   </div>

export default class extends Controller {
  static targets = ["button"]
  static values  = { content: String, successText: { type: String, default: "Copied!" } }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.contentValue)
      this._showFeedback()
    } catch {
      // Fallback for older browsers or non-HTTPS.
      this._legacyCopy(this.contentValue)
      this._showFeedback()
    }
  }

  // ── Private ──────────────────────────────────────────────────────── //

  _showFeedback() {
    if (!this.hasButtonTarget) return
    const btn = this.buttonTarget
    const original = btn.textContent
    btn.textContent = this.successTextValue
    btn.classList.add("text-emerald-400")
    setTimeout(() => {
      btn.textContent = original
      btn.classList.remove("text-emerald-400")
    }, 2000)
  }

  _legacyCopy(text) {
    const el = document.createElement("textarea")
    el.value = text
    el.style.cssText = "position:fixed;opacity:0"
    document.body.appendChild(el)
    el.select()
    document.execCommand("copy")
    document.body.removeChild(el)
  }
}
