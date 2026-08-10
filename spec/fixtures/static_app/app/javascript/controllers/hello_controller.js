import { Controller } from "@hotwired/stimulus"

// Basic Stimulus controller with targets, values, actions, and lifecycle
export default class extends Controller {
  static targets = ["output", "input", "counter"]
  static values = { greeting: { type: String, default: "Hello" }, count: Number }
  static outlets = ["search", "results"]
  static classes = ["active", "hidden"]

  connect() {
    this.countValue = 0
  }

  greet() {
    this.outputTarget.textContent = `${this.greetingValue}, World!`
    this.countValue++
    this.counterTarget.textContent = this.countValue
  }

  clear() {
    this.outputTarget.textContent = ""
    this.inputTarget.value = ""
  }

  toggle() {
    this.outputTarget.classList.toggle(this.activeClass)
  }
}
