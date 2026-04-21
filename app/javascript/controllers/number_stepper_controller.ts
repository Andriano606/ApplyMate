import { Controller } from '@hotwired/stimulus';

export default class NumberStepperController extends Controller {
  static targets = ['input'];

  declare readonly inputTarget: HTMLInputElement;

  increment() {
    const current = parseInt(this.inputTarget.value, 10) || 0;
    this.inputTarget.value = String(current + 1);
    this.inputTarget.dispatchEvent(new Event('change', { bubbles: true }));
  }

  decrement() {
    const current = parseInt(this.inputTarget.value, 10) || 0;
    const min = parseInt(this.inputTarget.min, 10);
    const next = isNaN(min) ? current - 1 : Math.max(min, current - 1);
    this.inputTarget.value = String(next);
    this.inputTarget.dispatchEvent(new Event('change', { bubbles: true }));
  }
}
