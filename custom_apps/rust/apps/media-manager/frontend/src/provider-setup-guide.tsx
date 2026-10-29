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
        text: "Register or sign in at OpenSubtitles.com and complete any email verification. An old OpenSubtitles.org account must be imported or linked on the .com site before using this REST API.",
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
      "There is no separate Test connection button for this provider. After saving, try identifying a music track. If the key is rejected, check that you copied the application key instead of the user submission key.",
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
      "There is no separate Test connection button. After saving, search for a book using Google Books. If Google rejects the request, check that Books API is enabled in the key's project, that its restrictions allow server requests and that the project's quota has not been exhausted.",
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
      "Wait for this integration to become available before arranging access. TheTVDB's licensing model determines whether a key, subscriber PIN or both are required; check those requirements before paying.",
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
        text: "Keep the key type with your saved value. Fanart.tv distinguishes a project API key (api_key) from a personal key (client_key); they are not interchangeable fields. Check which type Media Manager requests when this integration becomes available.",
        link: {
          label: "Read Fanart.tv authentication guidance",
          href: "https://api.fanart.tv/",
        },
      },
    ],
    credentialHelp: {
      apiKey:
        "Check the supported key type when this integration is available: Fanart.tv issues separate project and personal keys.",
    },
    troubleshooting:
      "New artwork can take longer to appear depending on your access tier. Wait for the integration's supported key fields before purchasing a membership for it.",
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
        text: "Read TheAudioDB's current music API guide first. Its free v1 test access and issued premium keys have different capabilities; the version and access tier matter.",
        link: {
          label: "Read TheAudioDB API guide",
          href: "https://www.theaudiodb.com/free_music_api",
        },
      },
      {
        text: "For an issued key, follow the API Key Application page, create or sign in to the requested account, and describe Media Manager as a personal music metadata and artwork lookup application. Use your Media Manager URL if asked for a website.",
        link: {
          label: "Open TheAudioDB key application",
          href: "https://www.theaudiodb.com/api_apply.php",
        },
      },
      {
        text: "Keep the issued key and its plan/version details. Copy the key alone, rather than an example API URL. Check which access tier the Media Manager integration supports when it becomes available.",
      },
    ],
    credentialHelp: {
      apiKey:
        "Use the key for the API version and access tier supported by the integration once it is available.",
    },
    troubleshooting:
      "Avoid purchasing access while this integration is coming soon. A key for one API version or tier may not unlock endpoints from another tier.",
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
      "This is an optional paid provider. Wait until the integration is available before subscribing for Media Manager; account access and API access can have different requirements.",
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
      "If the activation email does not arrive, check spam and the provider's support information. A signup problem must be resolved with Podcast Index before credentials can work in an application.",
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
      "A quota error can occur with a valid key. Review your current allowance or wait for its reset; a paid plan does not enable a Media Manager integration that is still coming soon.",
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
