import { Controller } from '@hotwired/stimulus';

export default class FlashController extends Controller {
  static targets = ['message'];

  declare messageTargets: HTMLElement[];

  messageTargetConnected(message: HTMLElement): void {
    setTimeout(() => {
      this.dismissMessage(message);
    }, 5000);
  }

  dismiss(event: Event): void {
    const message = (event.currentTarget as HTMLElement).closest(
      '[data-flash-target="message"]',
    ) as HTMLElement;
    if (message) {
      this.dismissMessage(message);
    }
  }

  private dismissMessage(message: HTMLElement): void {
    if (!message.isConnected) return;

    message.classList.remove('animate-slide-in');
    message.classList.add('animate-slide-out');
    message.addEventListener(
      'animationend',
      () => {
        message.remove();
      },
      { once: true },
    );
  }
}
