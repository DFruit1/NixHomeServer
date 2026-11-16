import { component$ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import { guideHref } from '../../shared/guide-data.js';

/** The checks that resolve most problems, in the order worth trying them. */
export const HelpTopic = component$(({ serverLanHost }: { serverLanHost?: string }) => (
  <article id="guide-detail" class="guide-topic doc-prose">
    <header class="guide-topic__head">
      <div class="guide-topic__title">
        <h1>Troubleshooting</h1>
      </div>
    </header>
    <p class="doc-lead">Try these checks before asking for help.</p>

    <ol class="doc-steps">
      <li>
        <strong>Check the network.</strong> Private apps load only on the home network or through NetBird.
        {serverLanHost && <> At home the server is <code>{serverLanHost}</code>.</>} Never click through a certificate warning.
      </li>
      <li>
        <strong>Sign out and back in.</strong> Access is read when you sign in, so a change an admin just made does not show until the next sign-in.
      </li>
      <li>
        <strong>Give a first visit a second try.</strong> Some apps create your profile the first time you open them. Do not create a second account while that is happening.
      </li>
      <li>
        <strong>Work out which sign-in is failing.</strong> If the Kanidm page accepts you and the app then asks for another password, the problem is the app’s own login. Resetting your Kanidm password will not fix it. See <Link href={guideHref('access')}>How sign-in works</Link>.
      </li>
      <li>
        <strong>A file did not appear.</strong> Check it is in <Link href={guideHref('folders')}>the folder that app reads</Link> and give the app time to scan. Large libraries take a while.
      </li>
    </ol>

    <h2>Asking an admin</h2>
    <dl class="doc-facts">
      <div>
        <dt>Include</dt>
        <dd>Your username, the app, roughly when it happened, which network you were on, and the exact error text.</dd>
      </div>
      <div>
        <dt>Never include</dt>
        <dd>Passwords, one-time links, recovery or authenticator codes, API keys, or an SSH private key.</dd>
      </div>
    </dl>
  </article>
));
