import { Controller } from "@hotwired/stimulus"
import debounce from "lodash/debounce"

// Stimulus controller with outlets, classes, and external imports
export default class extends Controller {
  static targets = ["input", "results", "spinner"]
  static values = { url: String, minLength: { type: Number, default: 3 } }
  static outlets = ["filter-form", "results-list"]
  static classes = ["loading", "empty"]

  connect() {
    this.search = debounce(this.search.bind(this), 300)
  }

  disconnect() {
    this.search.cancel?.()
  }

  async search() {
    const query = this.inputTarget.value
    if (query.length < this.minLengthValue) return

    this.spinnerTarget.classList.remove(this.emptyClass)
    this.element.classList.add(this.loadingClass)

    const response = await fetch(`${this.urlValue}?q=${encodeURIComponent(query)}`)
    const html = await response.text()
    this.resultsTarget.innerHTML = html

    this.element.classList.remove(this.loadingClass)

    if (this.hasResultsListOutlet) {
      this.resultsListOutlet.update()
    }
  }

  clear() {
    this.inputTarget.value = ""
    this.resultsTarget.innerHTML = ""
    if (this.hasFilterFormOutlet) {
      this.filterFormOutlet.reset()
    }
  }
}
