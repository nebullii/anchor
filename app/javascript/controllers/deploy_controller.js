import { Controller } from "@hotwired/stimulus"

// Manages the deploy button — shows a loading state on submit and prevents
// double-clicking while a deployment is being queued.
//
// Usage:
//   <%= button_to deploy_project_path(@project), method: :post,
//         data: { controller: "deploy", action: "deploy#submit" } do %>
//     Deploy
//   <% end %>

export default class extends Controller {
  static targets = ["button", "label"]
  static values  = { loadingText: { type: String, default: "Deploying…" } }

  submit(event) {
    // Prevent double-submission.
    if (this.element.dataset.submitting) {
      event.preventDefault()
      return
    }

    this.element.dataset.submitting = "true"
    this._setLoading(true)

    // Re-enable after 10s as a fallback (Turbo redirect will navigate away anyway).
    setTimeout(() => this._setLoading(false), 10_000)
  }

  // ── Private ──────────────────────────────────────────────────────── //

  _setLoading(loading) {
    const btn = this.hasButtonTarget ? this.buttonTarget : this.element.querySelector("input, button")
    if (!btn) return

    if (loading) {
      this._originalText = btn.value || btn.textContent
      if (btn.tagName === "INPUT") {
        btn.value = this.loadingTextValue
      } else {
        btn.textContent = this.loadingTextValue
      }
      btn.disabled = true
      btn.classList.add("opacity-60", "cursor-not-allowed")
    } else {
      if (btn.tagName === "INPUT") {
        btn.value = this._originalText
      } else {
        btn.textContent = this._originalText
      }
      btn.disabled = false
      btn.classList.remove("opacity-60", "cursor-not-allowed")
      delete this.element.dataset.submitting
    }
  }
}
