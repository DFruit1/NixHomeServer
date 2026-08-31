import { component$ } from '@builder.io/qwik';

export const DetailedGuideOverview = component$(({ enabledServiceCount }: { enabledServiceCount: number }) => (
  <article id="guide-detail" class="guide-panel detailed-guide-overview">
    <span class="eyebrow">Reference guide</span>
    <h2>Overview</h2>
    <p class="guide-lead">Use this guide when you want to understand an app, choose where a file belongs, connect a device, or diagnose an access problem. Your account currently has {enabledServiceCount} enabled app{enabledServiceCount === 1 ? '' : 's'} in this guide.</p>

    <section>
      <h3>Choose the right place to start</h3>
      <ul class="guide-checklist">
        <li><strong>Services</strong> is the launcher. Use it when you already know which app you need.</li>
        <li><strong>Getting Started</strong> is the hands-on checklist for first sign-in, recovery, uploads, SSHFS setup, and device enrolment.</li>
        <li><strong>Detailed Guide</strong> is the long-form reference for what every app does, how it handles access and files, and what to check when something fails.</li>
      </ul>
    </section>

    <section>
      <h3>How sign-in and access work</h3>
      <p>Homepage and most apps use Kanidm. The apps shown to you also depend on the access groups assigned to your account. Passwords, Videos, Local Backups, and Monitor can have an additional app-specific credential or sign-in path; each service topic calls out the correct boundary.</p>
      <aside class="guide-callout neutral">If access was changed recently, sign out of Homepage and the affected app, then sign back in once. Repeatedly changing your Kanidm password will not fix an app-specific password or missing group.</aside>
    </section>

    <section>
      <h3>How files move through the server</h3>
      <ol class="steps">
        <li>Use an app’s own uploader when it manages special metadata, such as Photos or Documents.</li>
        <li>Use Files for a few ordinary files and SSHFS for repeated or large transfers from a computer.</li>
        <li>Choose the destination from the File placement section. Personal and shared paths grant different audiences access.</li>
        <li>Upload one test item and wait for the destination app to scan it before moving a large library.</li>
      </ol>
    </section>

    <section>
      <h3>Profile preferences</h3>
      <p>“Show inactive apps in Services” controls inactive launcher cards. “Show unused apps in Detailed Guide” independently reveals reference topics for apps and file workflows that are not currently enabled. Both preferences are off by default and are stored only in this browser profile.</p>
    </section>

    <section>
      <h3>Safe troubleshooting</h3>
      <ul class="guide-checklist">
        <li>Use the home network or NetBird for private web apps. Never bypass a browser certificate warning.</li>
        <li>Record the app name, time, network path, and exact error before retrying so an administrator can correlate it with server logs.</li>
        <li>Never send passwords, SSH private keys, one-time links, recovery codes, authenticator codes, or API tokens in a support request.</li>
        <li>Do not delete, recreate, or duplicate an app account while first-login provisioning or reconciliation may still be running.</li>
      </ul>
    </section>
  </article>
));
