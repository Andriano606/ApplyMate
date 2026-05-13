import { Controller } from '@hotwired/stimulus';

export default class extends Controller {
  static targets = ['source', 'button'];

  declare readonly sourceTarget: HTMLElement;
  declare readonly buttonTarget: HTMLElement;

  copy(): void {
    const text = this.sourceTarget.textContent?.trim() ?? '';
    navigator.clipboard.writeText(text).then(() => {
      const original = this.buttonTarget.innerHTML;
      this.buttonTarget.textContent = '✓';
      this.buttonTarget.classList.add('!text-green-400');
      setTimeout(() => {
        this.buttonTarget.innerHTML = original;
        this.buttonTarget.classList.remove('!text-green-400');
      }, 1500);
    });
  }
}
