import { Controller } from "@hotwired/stimulus"

// Shows how many characters a comment has left and holds the submit button past the limit.
export default class extends Controller {
  static targets = ["body", "counter", "submit"]
  static values = { max: { type: Number, default: 2000 } }

  connect() {
    this.update()
  }

  update() {
    const left = this.maxValue - this.bodyTarget.value.length
    this.counterTarget.textContent = `${left} characters left`
    this.submitTarget.disabled = left < 0
  }
}
