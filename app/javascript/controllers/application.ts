import { Application } from '@hotwired/stimulus';

const application = Application.start();

// Configure Stimulus development experience
application.debug = false;
(window as unknown as { Stimulus: Application }).Stimulus = application;

export { application };
