import { Controller } from "@hotwired/stimulus"

// Stimulus controller demonstrating multi-controller composition patterns
export default class extends Controller {
  static targets = ["tab", "panel"]
  static values = { activeIndex: { type: Number, default: 0 } }

  connect() {
    this.showTab(this.activeIndexValue)
    document.addEventListener("turbo:before-fetch-request", this.handleTurboFetch.bind(this))
  }

  disconnect() {
    document.removeEventListener("turbo:before-fetch-request", this.handleTurboFetch.bind(this))
  }

  select(event) {
    const index = parseInt(event.currentTarget.dataset.index)
    this.activeIndexValue = index
    this.showTab(index)
  }

  showTab(index) {
    this.tabTargets.forEach((tab, i) => {
      tab.classList.toggle("active", i === index)
      tab.setAttribute("aria-selected", i === index)
    })
    this.panelTargets.forEach((panel, i) => {
      panel.hidden = i !== index
      panel.setAttribute("aria-hidden", i !== index)
    })
  }

  handleTurboFetch(event) {
    // Turbo event listener integration
  }
}
