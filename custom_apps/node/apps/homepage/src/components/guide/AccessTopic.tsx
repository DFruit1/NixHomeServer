import { component$ } from '@builder.io/qwik';
import { Link } from '@builder.io/qwik-city';
import { guideHref, separateLogins } from '../../shared/guide-data.js';
import type { ServiceCard } from '../../shared/types.js';

/** How the Kanidm sign-in, access groups and the few separate app logins fit together. */
export const AccessTopic = component$(({ services, kanidmUrl }: { services: ServiceCard[]; kanidmUrl: string }) => {
  const exceptions = services.filter((service) => separateLogins[service.id]);

  return (
    <article id="guide-detail" class="guide-topic doc-prose">
      <header class="guide-topic__head">
        <div class="guide-topic__title">
          <h1>How sign-in works</h1>
        </div>
        <p class="doc-actions">
          <a class="doc-btn" href={kanidmUrl} target="_blank" rel="noreferrer">Open Kanidm</a>
        </p>
      </header>
      <p class="doc-lead">One account, managed by Kanidm, signs you in to Homepage and almost every app. What you can open is decided by the groups an admin has put your account in.</p>

      <h2>When access changes</h2>
      <ul>
        <li>Your groups are read when you sign in. After an admin grants or removes access, sign out of Homepage and sign back in to see the change.</li>
        <li>Some apps create your profile the first time you open them, so a first visit can be slow or briefly blank. Try once more before reporting it.</li>
        <li>An app that is missing from Services is one your account has not been given. Ask an admin; changing your password will not add it.</li>
      </ul>

      {exceptions.length > 0 && (
        <>
          <h2>Apps with their own login</h2>
          <p>These ask for something other than your Kanidm sign-in. Save each one as its own entry in your password manager.</p>
          <dl class="doc-facts">
            {exceptions.map((service) => (
              <div key={service.id}>
                <dt><Link href={guideHref(`service-${service.id}`)}>{service.name}</Link></dt>
                <dd>{separateLogins[service.id]!.detail}</dd>
              </div>
            ))}
          </dl>
        </>
      )}

      <h2>Private apps and public links</h2>
      <ul>
        <li>Private apps open only on the home network or through NetBird. From anywhere else they will not load at all.</li>
        <li>A public share link is for sending an album or file to someone else. It is not a way to sign in, and it is never the server address for a phone app.</li>
        <li>Never click through a browser certificate warning. Stop and tell an admin instead.</li>
      </ul>

      <h2>If you are locked out</h2>
      <ul>
        <li>An admin can send you a new one-time link. It works once and expires after an hour.</li>
        <li>Never send anyone your password, a one-time link, a passkey, an authenticator code or a recovery code. An admin does not need them to help you.</li>
        <li>Keep a second way to sign in, such as a passkey on another device or an authenticator app, so one lost phone is not a lockout.</li>
      </ul>
    </article>
  );
});
