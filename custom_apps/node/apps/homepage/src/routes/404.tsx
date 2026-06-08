import { component$ } from '@builder.io/qwik';
import { Link, type DocumentHead } from '@builder.io/qwik-city';

export default component$(() => (
  <section class="section">
    <div class="empty-state">
      <h2>Page Not Found</h2>
      <p>This homepage route does not exist.</p>
      <Link class="open-link" href="/">
        Back to services
      </Link>
    </div>
  </section>
));

export const head: DocumentHead = {
  title: 'Page Not Found | Sydney Basin Services',
};
