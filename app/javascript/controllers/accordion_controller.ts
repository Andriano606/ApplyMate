import { Controller } from '@hotwired/stimulus';

export default class AccordionController extends Controller {
  static targets = ['content', 'icon'];

  declare contentTarget: HTMLElement;
  declare iconTarget: HTMLElement;

  toggle(): void {
    this.contentTarget.classList.toggle('hidden');
    this.iconTarget.classList.toggle('rotate-180');
  }
}
