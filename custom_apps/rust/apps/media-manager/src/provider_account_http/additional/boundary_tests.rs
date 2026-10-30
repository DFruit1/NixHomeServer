use super::*;

// Every adapter has a distinct credential transport. This targeted fixture
// check addresses the concrete risk of leaking keys/tokens through normalized
// candidates or upstream-controlled artwork references, without live accounts.
#[tokio::test]
async fn all_adapters_bound_upstream_data_and_keep_credentials_private() {
    async fn upstream(request: axum::extract::Request) -> Json<Value> {
        let path = request.uri().path();
        let provider = path.trim_start_matches('/').split('/').next().unwrap_or("");
        let body = match provider {
            "omdb" => {
                json!({"Response":"True","imdbID":"tt0133093","Title":"The Matrix","Year":"1999","Type":"movie","Poster":"http://127.0.0.1/private"})
            }
            "tvdb" if path.ends_with("login") => {
                json!({"status":"success","data":{"token":"fixture-token"}})
            }
            "tvdb" if path.contains("/episodes/") => json!({"data":{"episodes":[]}}),
            "tvdb" => {
                assert_eq!(
                    request.headers().get("authorization").unwrap(),
                    "Bearer fixture-token"
                );
                json!({"data":{"id":1,"name":"Example series","firstAired":"2001-01-01","artworks":[]}})
            }
            "wikidata" => {
                json!({"entities":{"Q42":{"labels":{"en":{"value":"Example"}},"claims":{"P345":[{"rank":"normal","mainsnak":{"datavalue":{"value":"tt0133093"}}}]}}}})
            }
            "fanart" => {
                assert_eq!(
                    request.headers().get("api-key").unwrap(),
                    "fixtureonlysecret"
                );
                json!({"name":"Example","movieposter":[{"url":"https://assets.fanart.tv.evil.example/exfil.png"}]})
            }
            "discogs" => {
                assert_eq!(
                    request.headers().get("authorization").unwrap(),
                    "Discogs token=fixtureonlysecret"
                );
                json!({"id":249504,"title":"Example release","artists":[{"name":"Artist"}],"labels":[],"master_id":1,"released":"2001-01-01"})
            }
            "theaudiodb" => {
                assert!(path.contains("/fixtureonlysecret/"));
                json!({"album":[{"idAlbum":"1","strAlbum":"Example album","strArtist":"Artist","intYearReleased":"2001"}]})
            }
            "comic-vine" => {
                json!({"status_code":1,"results":{"id":42,"name":"Issue one","volume":{"name":"Series","id":5},"issue_number":"1.5","description":"<p>Summary</p>","person_credits":[],"site_detail_url":"https://comicvine.gamespot.com/example/4000-42/"}})
            }
            "isbndb" => {
                assert_eq!(
                    request.headers().get("authorization").unwrap(),
                    "fixtureonlysecret"
                );
                json!({"book":{"isbn13":"9780140328721","title":"Example edition","authors":["Author"],"date_published":"2001-01-01"}})
            }
            "audnexus" => {
                json!({"asin":"B000000001","title":"Example audiobook","authors":[{"name":"Author"}],"narrators":[{"name":"Narrator"}],"seriesPrimary":{"name":"Series","position":"2"}})
            }
            "podcast-index" => {
                assert_eq!(
                    request.headers().get("x-auth-key").unwrap(),
                    "fixtureonlysecret"
                );
                use sha1::{Digest, Sha1};
                let date = request
                    .headers()
                    .get("x-auth-date")
                    .unwrap()
                    .to_str()
                    .unwrap();
                assert_eq!(
                    request
                        .headers()
                        .get("authorization")
                        .unwrap()
                        .to_str()
                        .unwrap(),
                    format!(
                        "{:x}",
                        Sha1::digest(format!("fixtureonlysecretfixtureonlysecret{date}"))
                    )
                );
                json!({"status":"true","feeds":[{"id":1,"title":"Example podcast","author":"Host","url":"http://127.0.0.1/private-feed"}]})
            }
            "subdl" => {
                assert_eq!(
                    request.headers().get("authorization").unwrap(),
                    "Bearer fixtureonlysecret"
                );
                json!({"status":true,"subtitles":[{"nId":"fixture-download","release_name":"Example release","lang":"en","hi":false}]})
            }
            _ => panic!("unexpected fixture route"),
        };
        Json(body)
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        axum::serve(listener, Router::new().fallback(upstream))
            .await
            .unwrap();
    });
    let temp = tempfile::tempdir().unwrap();
    let store = Arc::new(
        ProviderAccountStore::open(
            &temp.path().join("accounts.sqlite3"),
            &temp.path().join("master.key"),
        )
        .unwrap(),
    );
    let mut endpoints = ProviderTestEndpoints::default();
    for (provider, base) in &mut endpoints.additional_api_bases {
        *base = format!("http://{address}/{provider}/");
    }
    let state = ProviderBrokerState::with_test_endpoints(store, endpoints).unwrap();
    let identity = Identity {
        subject: "owner".into(),
        username: "display".into(),
        groups: vec!["users".into()],
    };
    let saved = BTreeMap::from([
        ("apiKey".into(), "fixtureonlysecret".into()),
        ("apiSecret".into(), "fixtureonlysecret".into()),
    ]);
    for (provider, id) in [
        ("omdb", Some("tt0133093")),
        ("tvdb", Some("series:1")),
        ("wikidata", Some("Q42")),
        ("fanart", Some("tmdb:550")),
        ("discogs", Some("release:249504")),
        ("theaudiodb", None),
        ("comic-vine", Some("issue:42")),
        ("isbndb", Some("9780140328721")),
        ("audnexus", Some("B000000001")),
        ("podcast-index", None),
        ("subdl", None),
    ] {
        let request = LookupRequest {
            query: "Example".into(),
            id: id.map(str::to_string),
            ..Default::default()
        };
        let results = lookup(&state, &identity, provider, &saved, &request)
            .await
            .unwrap_or_else(|_| panic!("{provider} fixture failed"));
        assert!(!results.is_empty(), "{provider}");
        assert!(results.len() <= MAX_RESULTS);
        let encoded = serde_json::to_string(&results).unwrap();
        assert!(!encoded.contains("fixtureonlysecret"), "{provider}");
        assert!(!encoded.contains("fixture-token"), "{provider}");
        if provider == "omdb" || provider == "fanart" {
            assert!(results[0].artwork.is_empty());
        }
        if provider == "comic-vine" {
            assert_eq!(results[0].fields.get("volumeNumber").unwrap(), "1.5");
        }
        if provider == "audnexus" {
            assert_eq!(results[0].fields.get("narrators").unwrap(), "Narrator");
        }
    }
    server.abort();
}
