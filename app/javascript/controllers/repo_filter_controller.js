import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "list"]

  filter() {
    const query = this.inputTarget.value.toLowerCase().trim()
    const rows  = this.listTarget.querySelectorAll("[data-repo-filter-name]")

    rows.forEach(row => {
      const name = row.dataset.repoFilterName || ""
      row.style.display = name.includes(query) ? "" : "none"
    })
  }
}
