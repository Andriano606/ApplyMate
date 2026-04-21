import { Controller } from '@hotwired/stimulus';

export default class HelloController extends Controller {
  connect(): void {
    console.log('Hello World!');
  }
}
