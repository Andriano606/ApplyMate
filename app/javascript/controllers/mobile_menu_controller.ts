import { Controller } from '@hotwired/stimulus';

export default class MobileMenuController extends Controller {
  static targets = ['menu', 'burgerIcon', 'closeIcon'];

  declare menuTarget: HTMLElement;
  declare burgerIconTarget: HTMLElement;
  declare closeIconTarget: HTMLElement;
  declare hasMenuTarget: boolean;

  toggle(): void {
    if (!this.hasMenuTarget) return;

    const isHidden = this.menuTarget.classList.contains('hidden');
    this.menuTarget.classList.toggle('hidden', !isHidden);
    this.burgerIconTarget.classList.toggle('hidden', isHidden);
    this.closeIconTarget.classList.toggle('hidden', !isHidden);
  }
}
