import { Controller } from '@hotwired/stimulus';

export default class ImageSliderController extends Controller {
  static targets = ['track', 'dot'];

  declare trackTarget: HTMLElement;
  declare dotTargets: HTMLElement[];
  declare hasDotTarget: boolean;

  private currentIndex = 0;

  prev(event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    this.goTo(this.currentIndex - 1);
  }

  next(event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    this.goTo(this.currentIndex + 1);
  }

  private goTo(index: number): void {
    const count = this.dotTargets.length;
    if (count === 0) return;
    this.currentIndex = (index + count) % count;
    this.trackTarget.scrollTo({
      left: this.currentIndex * this.trackTarget.offsetWidth,
      behavior: 'smooth',
    });
    this.updateDots();
  }

  private updateDots(): void {
    this.dotTargets.forEach((dot, i) => {
      dot.classList.toggle('opacity-100', i === this.currentIndex);
      dot.classList.toggle('opacity-40', i !== this.currentIndex);
    });
  }
}
