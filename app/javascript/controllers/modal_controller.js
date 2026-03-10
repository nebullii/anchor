import { Controller } from "@hotwired/stimulus"

// Generic modal controller.
// The modal is injected via Turbo Streams into a placeholder div.
// On close, the placeholder is restored so future Turbo Stream replaces work.
//
// Usage (in a partial that replaces #some_modal):
//   <div id="some_modal"
//        data-controller="modal"
//        data-action="keydown.esc@window->modal#close click->modal#backdropClick">
//     <div data-modal-target="backdrop" class="fixed inset-0 ...">
//       <div data-modal-target="panel" class="...">...</div>
//     </div>
//   </div>

export default class extends Controller {
  static targets = ["backdrop", "panel"]

  connect() {
    document.body.classList.add("overflow-hidden")
    // Notify other controllers (e.g. deploy) that a modal opened
    document.dispatchEvent(new CustomEvent("modal:opened"))
    // Focus first focusable element
    requestAnimationFrame(() => {
      this.element.querySelector("a[href], button, input, textarea, select")?.focus()
    })
  }

  disconnect() {
    document.body.classList.remove("overflow-hidden")
  }

  close() {
    document.body.classList.remove("overflow-hidden")
    // Restore the empty placeholder so future Turbo Stream replaces work
    const placeholder = document.createElement("div")
    placeholder.id = this.element.id
    this.element.replaceWith(placeholder)
  }

  backdropClick(event) {
    // Close only when clicking the backdrop itself, not the panel
    if (this.hasBackdropTarget && event.target === this.backdropTarget) {
      this.close()
    }
  }
}
