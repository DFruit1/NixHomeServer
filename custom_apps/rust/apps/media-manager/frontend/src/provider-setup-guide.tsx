import { component$ } from "@builder.io/qwik";

interface SetupStep {
  text: string;
  link?: { label: string; href: string };
  fields?: { label: string; value: string }[];
}

interface SetupGuide {
  steps: SetupStep[];
  credentialHelp: Record<string, string>;
  troubleshooting: string;
}

// Keep these instructions beside the credential UI: they describe provider
// websites, not a change to the server's credential or capability contract.
export const PROVIDER_SETUP_GUIDES: Record<string, SetupGuide> = {
  tmdb: {
    steps: [
      {
        text: "Create a TMDB account with a username, email address and password. Follow the activation email, then sign in. This is a separate account from your Media Manager sign-in.",
        link: {
          label: "Create a TMDB account",
          href: "https://www.themoviedb.org/signup",
        },
      },
      {
        text: "Open your account settings → API. Request an API key, choose Developer for personal use, and read and accept TMDB's terms. If you already have API access, go straight to the token on this page.",
        link: {
          label: "Open TMDB API settings",
          href: "https://www.themoviedb.org/settings/api",
        },
      },
      {
        text: "For a private home library, fill in the application form as follows. These are suggested descriptions of your use, rather than values issued by TMDB.",
        fields: [
          { label: "Application Name", value: "Media Manager" },
          {
            label: "Application URL",
            value:
              "Use the address you normally open Media Manager at, including https://. Copy it from your browser's address bar and omit the ?view=… part.",
          },
          {
            label: "Type of Use",
            value:
              "Website, if offered, because Media Manager runs in your browser. Choose the option that describes your actual installation.",
          },
          {
            label: "Application Summary",
            value:
              "A private home media library using TMDB to look up movie and television metadata and artwork for my personal collection.",
          },
          {
            label: "Contact Info",
            value:
              "Enter your own name, email, phone number and postal address where required, and select your country. Address 2 is optional.",
          },
        ],
      },
      {
        text: "Submit the application. Return to Settings → API and copy the complete API Read Access Token. Media Manager uses this longer token, rather than the shorter API Key (v3 auth).",
      },
    ],
    credentialHelp: {
      apiKey:
        "Paste the complete API Read Access Token from Settings → API, without quotation marks or the word Bearer. Your TMDB password and the shorter API Key (v3 auth) will not work in this field.",
    },
    troubleshooting:
      "If the registration form is awkward on a phone, use your browser's desktop-site option or a desktop browser. A required Application URL needs the full Media Manager address. This is an application description, not a callback URL; you do not need to make your private library public.",
  },
  opensubtitles: {
    steps: [
      {
        text: "Create or sign in to an OpenSubtitles.com account and complete any email verification. Use credentials that work on the .com site; an older OpenSubtitles.org account can be imported through the provider's account-import process.",
        link: {
          label: "Open OpenSubtitles.com",
          href: "https://www.opensubtitles.com/",
        },
      },
      {
        text: "Open your profile's API Consumers page and choose New Consumer. Give the application a name such as Media Manager and describe it as personal subtitle search and download for a private home library. Complete the required fields and create the consumer.",
        link: {
          label: "Create an API consumer",
          href: "https://www.opensubtitles.com/consumers",
        },
      },
      {
        text: "Copy the consumer's application API key. You also need the username and password that let you sign in to OpenSubtitles.com; the API key alone does not supply your account's download access.",
      },
    ],
    credentialHelp: {
      apiKey:
        "Paste the API key shown for the consumer you created on OpenSubtitles.com → API Consumers.",
      username:
        "Enter your OpenSubtitles.com account username, as used to sign in there.",
      password:
        "Enter that account's password. If you normally use a linked login, make sure you have a working OpenSubtitles.com password first.",
      userAgent:
        "Optional: your registered application name. Leave blank to use Media Manager's default.",
    },
    troubleshooting:
      "If login is rejected, first confirm the same username and password work on OpenSubtitles.com and that email verification is complete. Download limits depend on your account; a quota error calls for waiting for the reset or reviewing your plan, rather than creating another key.",
  },
  acoustid: {
    steps: [
      {
        text: "Sign in to AcoustID with MusicBrainz or Google. AcoustID uses that existing account; there is no separate AcoustID password to enter in Media Manager.",
        link: {
          label: "Sign in to AcoustID",
          href: "https://acoustid.org/login",
        },
      },
      {
        text: "Register an application to obtain a client API key. Use Media Manager as the application name and describe personal music identification using locally calculated audio fingerprints. If a website is requested, use your Media Manager address.",
        link: {
          label: "Register an AcoustID application",
          href: "https://acoustid.org/new-application",
        },
      },
      {
        text: "Copy the application's API key. The personal user API key in your account settings is for submitting fingerprints and is a different credential. Media Manager needs the application key for lookups.",
      },
    ],
    credentialHelp: {
      apiKey:
        "Paste the application/client API key from your registered AcoustID application. Use your own key rather than a temporary key from documentation examples.",
    },
    troubleshooting:
      "Test connection checks the application key with a built-in synthetic fingerprint; it does not read your music. Then try Fingerprint mode on a cataloged track. If the key is rejected, copy the application key rather than the personal submission key. No matches means the recording may be absent from AcoustID; try artist and album-title search in MusicBrainz.",
  },
  "google-books": {
    steps: [
      {
        text: "Sign in to Google Cloud Console with your Google account. Use the project selector to create a project named Media Manager, or select an existing project you own.",
        link: {
          label: "Open Google Cloud Console",
          href: "https://console.cloud.google.com/",
        },
      },
      {
        text: "With that project selected, open APIs & Services → Library, find Books API and choose Enable. Check that you enabled it in the same project where you will create the key.",
        link: {
          label: "Enable Books API",
          href: "https://console.cloud.google.com/apis/library/books.googleapis.com",
        },
      },
      {
        text: "Open APIs & Services → Credentials → Create credentials → API key. If a wizard asks which data you need, choose public data. Copy the generated API key; Media Manager's book search does not need an OAuth client, consent screen, service-account file or your Google password.",
        link: {
          label: "Open project credentials",
          href: "https://console.cloud.google.com/apis/credentials",
        },
      },
      {
        text: "Edit the key's API restrictions, choose Restrict key, select Books API and save. Media Manager calls Google from its server, so a Websites/HTTP-referrer application restriction will not work. Any IP restriction must match the server's outgoing public IP, rather than your phone's or computer's IP.",
      },
    ],
    credentialHelp: {
      apiKey:
        "Paste the API key from your Google Cloud project's Credentials page. Do not paste an OAuth client ID, client secret or service-account JSON.",
    },
    troubleshooting:
      "Save and test sends a small book-search request. If access is rejected, check the selected project, Books API enablement and key restrictions. A quota limit can occur with a valid key; check the project's Books API quota and wait for its reset. A connected account does not guarantee a matching edition or cover.",
  },
  tvdb: {
    steps: [
      {
        text: "Create a TheTVDB account or sign in, then open API and Data Licensing → Get Started. Website membership by itself does not issue an application API key.",
        link: {
          label: "Open TheTVDB API access",
          href: "https://thetvdb.com/api-information",
        },
      },
      {
        text: "Review the licensing options for your use. For an application registration, describe Media Manager as a private home library retrieving television and movie metadata, and use your Media Manager address if a website is requested. Obtain the project's API key through TheTVDB's application process.",
      },
      {
        text: "A subscriber PIN is separate from the project API key and is only needed for subscription-based projects. If your selected access requires it, find the PIN in your subscriber account; otherwise leave the PIN field empty. Buying a subscription alone does not replace the project key.",
        link: {
          label: "Read about subscriber PINs",
          href: "https://thetvdb.com/subscribe",
        },
      },
    ],
    credentialHelp: {
      apiKey: "Use the project API key issued by TheTVDB.",
      pin: "Use your subscriber PIN only when the project's access model requires it.",
    },
    troubleshooting:
      "The project API key is required; a subscriber PIN supplements it only for projects using subscription access. Test connection checks login. If login works but an episode differs from your files, check the selected episode order and language before changing credentials.",
  },
  omdb: {
    steps: [
      {
        text: "Open the API key request page. Choose the free account option if its current daily limit meets your needs; Patreon access is optional. Enter your email and complete the requested name and use-description fields.",
        link: {
          label: "Request an OMDb API key",
          href: "https://www.omdbapi.com/apikey.aspx",
        },
      },
      {
        text: "For a use description, enter personal movie and television metadata lookups for a private Media Manager library. Submit the form, then check your email and spam folder for the key and any activation instructions.",
      },
      {
        text: "Follow the activation link in the email before using the key. Keep the key itself; the email address, activation URL and an IMDb title ID are different values.",
      },
    ],
    credentialHelp: {
      apiKey: "Use the API key sent by OMDb after completing email activation.",
    },
    troubleshooting:
      "If no email arrives, check spam and the delivery notice on OMDb's request page. An inactive-key error usually needs email activation; a daily-limit error needs the quota to reset.",
  },
  fanart: {
    steps: [
      {
        text: "Create an account or sign in to Fanart.tv, then open Get an API key. The page separates Project API Keys from Personal API Keys.",
        link: {
          label: "Open Fanart.tv API keys",
          href: "https://fanart.tv/get-an-api-key/",
        },
      },
      {
        text: "For a project key, register the application with a name such as Media Manager, your Media Manager URL and a description of artwork lookups for a private home library. Personal keys identify an end user's access and are issued separately in the Personal API Keys section.",
      },
      {
        text: "Enter a Project API key, a Personal API key, or both in the matching fields below. Media Manager supports Fanart.tv v3.2, which accepts a personal key on its own. When both are supplied, the personal key determines your access tier.",
        link: {
          label: "Read Fanart.tv authentication guidance",
          href: "https://api.fanart.tv/",
        },
      },
    ],
    credentialHelp: {
      apiKey:
        "Paste the key from Project API Keys. Leave empty if you are using only a Personal API key; at least one of the two fields must be filled.",
      clientKey:
        "Paste the key from Personal API Keys. This can be used alone or with the Project API key. Leave empty if you are using only a project key.",
    },
    troubleshooting:
      "A successful test confirms access to a known movie's artwork. Your chosen movie, series or music ID may still have no images. Recently added artwork can be delayed by the key's access tier; check the provider's current tier rules before changing keys or buying access.",
  },
  discogs: {
    steps: [
      {
        text: "Create a Discogs account, complete any email verification and sign in.",
      },
      {
        text: "Open your avatar menu → Settings → Developers. Generate a new personal access token and copy it. For a personal library, this token avoids registering a separate OAuth application.",
        link: {
          label: "Open Discogs developer settings",
          href: "https://www.discogs.com/settings/developers",
        },
      },
      {
        text: "Keep the personal access token in your password manager. It is different from an application's consumer key and consumer secret, and does not need a Discogs token= prefix when entered in a credential field.",
      },
    ],
    credentialHelp: {
      apiKey:
        "Use the personal access token from Settings → Developers, without an authorization-header prefix.",
    },
    troubleshooting:
      "If you revoke or regenerate the token in Discogs, any application using the old value must be updated. Keep your Discogs account password separate from the access token.",
  },
  theaudiodb: {
    steps: [
      {
        text: "Media Manager uses TheAudioDB v1. Open the official API guide and copy the current free v1 test key if its available endpoints meet your needs, or use your own premium key with v1 access. Check the guide for the current free key instead of copying an old example from another site.",
        link: {
          label: "Read TheAudioDB API guide",
          href: "https://www.theaudiodb.com/free_music_api",
        },
      },
      {
        text: "For your own premium key, sign in to TheAudioDB and use the key shown on your user profile after the account has API access. Review the current plan first; the shared v1 test key lets you try supported free lookups without a premium subscription.",
        link: {
          label: "Review TheAudioDB access options",
          href: "https://www.theaudiodb.com/free_music_api",
        },
      },
      {
        text: "Paste the key alone, not a full API URL or an X-API-KEY header. The v2 API has a different authentication method; v2-only examples do not describe this integration.",
      },
    ],
    credentialHelp: {
      apiKey:
        "Paste the current free v1 test key from the official guide, or your own key with v1 API access. Do not include the API URL or header name.",
    },
    troubleshooting:
      "Test connection checks an album lookup through v1. If other lookups fail, check whether those endpoints are included in your key's access tier. Artist biographies are shown as reference material; they are not automatically used as album descriptions.",
  },
  "comic-vine": {
    steps: [
      {
        text: "Open Comic Vine's API page. Under Grab an API key, choose Sign Up or Log In and complete any verification required for your account.",
        link: {
          label: "Open Comic Vine API access",
          href: "https://comicvine.gamespot.com/api/",
        },
      },
      {
        text: "Return to the API page while signed in to obtain your Comic Vine API key. Read the non-commercial-use terms and keep a copy of the key in your password manager.",
      },
      {
        text: "Use the key itself, rather than your website password or a key for another site. Comic Vine issues its own site-specific API keys.",
      },
    ],
    credentialHelp: {
      apiKey: "Use the Comic Vine API key from its API page while signed in.",
    },
    troubleshooting:
      "If the key is hidden, check that you are signed in on Comic Vine itself. Rate limits may temporarily block requests even with a valid key.",
  },
  isbndb: {
    steps: [
      {
        text: "Review ISBNdb's current API plans and create an account if you decide its paid catalog is needed. This is separate from the public, key-free Open Library source already available in Media Manager.",
        link: {
          label: "Review ISBNdb API access",
          href: "https://isbndb.com/isbn-database",
        },
      },
      {
        text: "After API access is enabled for your account, use ISBNdb's account area to obtain your API key. Follow the account's current key-generation or key-display instructions and save the value in your password manager.",
      },
      {
        text: "Use the issued API key, rather than an ISBN number, account password or subscription identifier. Check the plan's request allowance before relying on it for a library.",
      },
    ],
    credentialHelp: {
      apiKey: "Use the API key issued for your ISBNdb account's API access.",
    },
    troubleshooting:
      "This provider requires ISBNdb API access. Test connection uses a known ISBN and consumes an API request. Check that the key belongs to an active API plan and that its request allowance remains available. For a specific edition, copy its ISBN rather than searching by title alone.",
  },
  "podcast-index": {
    steps: [
      {
        text: "Open Podcast Index's API signup page, enter the requested account and contact details, and describe the use as podcast metadata lookups for a personal media library. Follow the signup and email activation instructions.",
        link: {
          label: "Sign up for Podcast Index API access",
          href: "https://api.podcastindex.org/signup",
        },
      },
      {
        text: "Obtain both the API key and its matching API secret from the API account's instructions. Save them together in your password manager; they are two different values and both are needed.",
      },
      {
        text: "Use the original key and secret. The authorization hash shown in request examples is calculated for an individual request and is not the value to save as your API secret.",
        link: {
          label: "Read Podcast Index API documentation",
          href: "https://podcastindex-org.github.io/docs-api/",
        },
      },
    ],
    credentialHelp: {
      apiKey: "Use the API key issued by Podcast Index.",
      apiSecret:
        "Use the matching original API secret, rather than a generated authorization hash.",
    },
    troubleshooting:
      "If activation fails, check spam and the provider's support information. If both original values are correct but authentication fails, the server's clock may need checking because requests are signed with a timestamp. Podcast results are for inspection here; feed and episode changes belong in Audiobookshelf.",
  },
  subdl: {
    steps: [
      {
        text: "Create a SubDL account or sign in, and complete any requested email verification. Open your account panel's API section.",
        link: {
          label: "Open SubDL API settings",
          href: "https://subdl.com/panel/api",
        },
      },
      {
        text: "Get your API key from that panel. If asked to name it, use Media Manager and describe personal subtitle search and downloads. Start with the free access tier if its limits meet your needs.",
      },
      {
        text: "Save the API key itself. A subtitle download link, subtitle ID or SubDL login password is a different value. Check the current search and download quotas in the API documentation.",
        link: {
          label: "Read SubDL API guidance",
          href: "https://subdl.com/api-doc",
        },
      },
    ],
    credentialHelp: {
      apiKey: "Use the API key from your SubDL account panel's API section.",
    },
    troubleshooting:
      "Media Manager uses SubDL's v1 search API. Test connection checks API access, not subtitle timing or remaining download allowance. If downloads are limited, check the account and outgoing server IP allowances in the provider's current documentation. Preview the selected file before preparing an installation.",
  },
};

export const ProviderSetupGuide = component$<{ providerId: string }>(
  ({ providerId }) => {
    const guide = PROVIDER_SETUP_GUIDES[providerId];
    if (!guide) return null;
    return (
      <div class="provider-access-guide">
        <ol class="provider-signup-steps">
          {guide.steps.map((step, index) => (
            <li key={index}>
              <p>{step.text}</p>
              {step.link && (
                <a href={step.link.href} target="_blank" rel="noreferrer">
                  {step.link.label}
                </a>
              )}
              {step.fields && (
                <dl class="provider-application-fields">
                  {step.fields.map((field) => (
                    <div key={field.label}>
                      <dt>{field.label}</dt>
                      <dd>{field.value}</dd>
                    </div>
                  ))}
                </dl>
              )}
            </li>
          ))}
        </ol>
        <p class="provider-setup-troubleshooting">
          <strong>Need help?</strong> {guide.troubleshooting}
        </p>
      </div>
    );
  },
);

interface UsageGuide {
  queryLabel?: string;
  queryPlaceholder?: string;
  steps: string[];
}

// These examples describe the syntax accepted by Media Manager's adapters,
// which can be narrower than the provider's own website or API.
export const PROVIDER_USAGE_GUIDES: Record<string, UsageGuide> = {
  tmdb: {
    steps: [
      "Open a movie or television item's Metadata editor and expand TMDB. Search the movie title or series title; check the year to distinguish remakes.",
      "For an episode, find its series first and check season and episode numbers before choosing the result. A series match alone does not identify an episode.",
      "Choose Compare fields, check the proposed values, then Add selected to draft. Preview poster is a separate artwork action. Review and confirm the resulting changes before anything is written.",
    ],
  },
  opensubtitles: {
    steps: [
      "Open subtitle management for the selected video, choose the required language, and search OpenSubtitles. Media Manager tries the local movie hash first and falls back to title search; the video is not uploaded.",
      "Check the release name, language, hearing-impaired flag and timing against your video. Preview the subtitle, then prepare and confirm its installation. A connection test does not download or install a subtitle.",
    ],
  },
  acoustid: {
    steps: [
      "After saving an application key, open a cataloged music track's Metadata editor and expand MusicBrainz. Select Fingerprint to identify its audio, or Auto to try a fingerprint before artist/title search.",
      "The server calculates the fingerprint locally and sends the fingerprint and duration to AcoustID, not the audio file. Review the resulting MusicBrainz release before adding fields or previewing its cover.",
      "A successful connection test checks the key only. If a track has no fingerprint match, use Search with its artist and album title; replacing a valid key will not add a missing recording to the provider's catalog.",
    ],
  },
  "google-books": {
    steps: [
      "Open a book's Metadata editor and expand Google Books. Search by title and author, or enter isbn:9780140328721 with your edition's own ISBN.",
      "Check the author, publisher, publication date, language and ISBN. Different printings and translations can have the same title. Use Compare fields to add chosen values to the draft, or Preview cover for a separate artwork change.",
      "Searches do not edit files. Preview and confirm your draft or cover change to apply it. Connected means the key works; it does not guarantee that Google has the edition or cover you need.",
    ],
  },
  musicbrainz: {
    steps: [
      "No MusicBrainz account or API key is needed for searches. In a music track's Metadata editor, expand MusicBrainz, select Search, and enter the artist and album title.",
      "Choose the release that matches your edition, date and track listing. A release group brings editions together; an individual release identifies a particular edition. AcoustID configuration is needed only for Fingerprint mode.",
      "Use Compare fields to select metadata for the draft. A Cover Art Archive cover is a separate preview and confirmation. Requests are paced automatically; wait for a search to finish before retrying.",
    ],
  },
  "cover-art-archive": {
    steps: [
      "No account or key is needed. Find and select a release through the MusicBrainz panel in a music item's Metadata editor; Cover Art Archive uses that release's MusicBrainz ID, not a title search.",
      "Preview the front cover and check that it matches the edition. Prepare the artwork change, review its preview and confirm installation. A release can have correct metadata but no archived cover; try the matching edition or another artwork source.",
    ],
  },
  "open-library": {
    steps: [
      "No Open Library account or key is needed. In a book or audiobook's Metadata editor, search Open Library by title and author, or by the book edition's ISBN.",
      "A work groups editions together. Expand its editions and check publisher, publication date, language and ISBN before choosing one. An audiobook's print ISBN can identify the book, but does not establish its narrator or audio edition.",
      "Choose Compare fields and add only the values you want to the draft. Preview cover is a separate action. Review and confirm changes before applying them; a missing cover does not invalidate the book record.",
    ],
  },
  wikidata: {
    queryLabel: "Title or Wikidata Q ID",
    queryPlaceholder: "e.g. Dune or Q172241",
    steps: [
      "No account or key is needed. Search the title, or enter a Wikidata item ID beginning with Q. Use View details on a title result to retrieve linked provider identifiers.",
      "Check the description to distinguish a book, film, series or adaptation with the same name. Compare fields lets you review identifiers before adding them to the draft. Ambiguous identifier claims can be omitted; do not guess a missing ID.",
    ],
  },
  audnexus: {
    queryLabel: "Audiobook ASIN",
    queryPlaceholder: "10-character ASIN from the Audible edition",
    steps: [
      "No account or key is needed. Copy the ten-character ASIN from the Audible audiobook edition, paste it here and select the edition's region, such as US, UK or AU. This lookup does not search by title or ISBN.",
      "Check the narrator, language, abridged status and series position before using Compare fields or Choose artwork. If no record is returned, check the ASIN and region; another edition can have a different ASIN.",
    ],
  },
  tvdb: {
    queryLabel: "Series or movie title",
    queryPlaceholder: "e.g. The Expanse",
    steps: [
      "Search the series or movie title and open View details for the matching result. For television, select Aired / official, DVD or Absolute order to match the order used by your files.",
      "Enter a three-letter language code, such as eng, for translated details. Check season and episode numbering before comparing fields; changing order can change which episode a number identifies.",
      "Use Compare fields to add chosen metadata to the draft, or Choose artwork to preview a supported image. Review and confirm those changes separately before applying them.",
    ],
  },
  omdb: {
    queryLabel: "Movie or series title",
    queryPlaceholder: "e.g. The Matrix",
    steps: [
      "Search the title and choose View details for the correct result. Check the year, movie/series/episode type and IMDb ID before comparing fields; ratings are reference information from the returned record.",
      "Compare fields adds selected values to the draft. Choose artwork previews an available poster separately. If access is rejected, check email activation; if the daily limit is reached, wait for the allowance to reset.",
    ],
  },
  fanart: {
    queryLabel: "Matched provider ID",
    queryPlaceholder: "e.g. tmdb:550 or tvdb:121361",
    steps: [
      "Match the item to a provider first, then enter its ID with the source prefix: tmdb:550 or imdb:tt0137523 for a movie, tvdb:121361 for a series, or musicbrainz-artist:UUID / musicbrainz-release-group:UUID for music. Replace UUID with the ID from the MusicBrainz page.",
      "Fanart.tv looks up artwork by ID; it does not search titles. Choose artwork, select the image's role and language, and preview it before confirming installation. A clear logo, backdrop and cover have different roles and are not interchangeable.",
    ],
  },
  discogs: {
    queryLabel: "Release title, barcode, catalog number or Discogs ID",
    queryPlaceholder: "e.g. Nevermind, barcode:720642442517 or release:249504",
    steps: [
      "Search a release title with its artist, or use barcode:NUMBER, catalog:NUMBER, release:ID or master:ID. Use the numeric ID from the matching Discogs page; a master groups several releases.",
      "Open View details and verify the pressing, format, country, label and catalog number against your copy. Compare fields and Choose artwork let you review metadata and images before preparing and confirming changes.",
    ],
  },
  theaudiodb: {
    queryLabel: "Album title or artist reference",
    queryPlaceholder: "e.g. Homework or artist:Daft Punk",
    steps: [
      "For an album, enter its title and artist. For an artist record, use artist:NAME or artist:ID. You can also look up an album with musicbrainz-release-group:UUID using its MusicBrainz release-group ID.",
      "Check the artist and release year before comparing album fields or choosing artwork. Artist biographies appear as reference information; they are not used as album descriptions. Review and confirm any draft or artwork change.",
    ],
  },
  "comic-vine": {
    queryLabel: "Comic series / volume title",
    queryPlaceholder: "e.g. Batman",
    steps: [
      "Search the comic series title. Comic Vine calls a series run a volume: check its start year and publisher, then choose View details to browse its issues. Select the correct issue, not just a volume with a similar name.",
      "Check issue number, cover date, creators and cover before Compare fields or Choose artwork. Review and confirm the selected changes; this lookup does not automatically rewrite an entire comic series.",
    ],
  },
  isbndb: {
    queryLabel: "ISBN or book title",
    queryPlaceholder: "e.g. 9780140328721 or Matilda",
    steps: [
      "Enter the edition's ISBN-10 or ISBN-13 for an exact lookup, or use its title for a broader search. Spaces and hyphens in an ISBN are accepted; an ISBN with an invalid check digit is rejected.",
      "Check the binding, edition, language, publisher and publication date before comparing fields. This source supplies metadata here; use a book artwork source for covers. A connection test and every lookup consume API requests, so avoid repeating the same search when your allowance is low.",
    ],
  },
  "podcast-index": {
    queryLabel: "Podcast title",
    queryPlaceholder: "e.g. Rustacean Station",
    steps: [
      "Search a podcast title and check the publisher and feed before choosing View details. A feed result can show a bounded list of its episodes; this is not a full archive or an automatic subscription.",
      "Use the results to inspect feed, episode and podcast-namespace information. Feed and episode editing belongs in Audiobookshelf; this source does not add podcast fields to a portable metadata draft here.",
    ],
  },
  subdl: {
    steps: [
      "Open SubDL in the video's subtitle tools. Choose a language code such as en, check the movie/series title and, for television, the season and episode. The saved IMDb or TMDB ID helps identify the title when available.",
      "Check the release name, language and hearing-impaired information. Choose Preview subtitle; if an archive contains several files, select the file for your episode. Review the cues and timing before preparing and confirming installation.",
    ],
  },
};

export const ProviderUsageGuide = component$<{ providerId: string }>(
  ({ providerId }) => {
    const guide = PROVIDER_USAGE_GUIDES[providerId];
    if (!guide) return null;
    return (
      <details class="provider-use-guide">
        <summary>How to use this source</summary>
        <ol class="provider-signup-steps">
          {guide.steps.map((step, index) => (
            <li key={index}>
              <p>{step}</p>
            </li>
          ))}
        </ol>
      </details>
    );
  },
);
