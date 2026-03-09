import { Controller } from "@hotwired/stimulus"

// Autofills project name and branch when a repository is selected.
export default class extends Controller {
  static targets = ["select", "name", "branch"]

  fill() {
    const option = this.selectTarget.selectedOptions[0]
    if (!option || !option.value) return

    const repoName   = option.dataset.name
    const repoBranch = option.dataset.branch

    // Only fill name if it's still empty
    if (this.nameTarget.value === "") {
      this.nameTarget.value = repoName
    }

    // Always fill branch from repo default
    if (this.branchTarget.value === "" || this.branchTarget.value === "main") {
      this.branchTarget.value = repoBranch || "main"
    }
  }
}
