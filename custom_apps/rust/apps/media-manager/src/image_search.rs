//! Tag matching for the private photo index.
//!
//! EYE saves lowercase identifiers such as `rock`, `personal_computer` and
//! `moths_and_butterflies`. People type `Rocks`, `rock's`, `personal computer`
//! or wording EYE does not use (`woods`), so matching the saved spelling only
//! missed photos the user meant. Each typed term becomes a bounded candidate
//! set instead:
//!
//! 1. the term itself and its other grammatical forms,
//! 2. vocabulary tags that contain the word (the `butterflies` in
//!    `moths_and_butterflies`),
//! 3. curated wording for the same or a nearby subject ([`FAMILIES`] and
//!    [`ASSOCIATIONS`]), which the caller can switch off.
//!
//! Candidates only widen what a term may match. Terms stay in separate groups,
//! so "all tags" still needs one match per typed word. Everything runs locally
//! against the pinned vocabulary: no model runs during a search and no query
//! leaves the server.
use serde::Serialize;
use std::collections::BTreeSet;

/// Most comma-separated terms one search may carry.
pub(crate) const MAX_TERMS: usize = 32;
/// Most candidate tags generated for one typed term.
pub(crate) const MAX_CANDIDATES: usize = 32;
/// Most matched tags reported back for one term.
pub(crate) const MAX_REPORTED_TAGS: usize = 8;
/// Most terms whose matched tags are reported.
pub(crate) const MAX_REPORTED_TERMS: usize = 16;

/// Tag identifiers in the pinned EYE model metadata (`eye_meta.json`, sha256
/// 3678669c840378bca191250597e3a77e5b478e12d3e70c48f827b860551f791c). They
/// are used only to recognise a word inside a compound tag and to keep the
/// curated relations honest; an EYE tag outside this list still matches its
/// own spelling. Update both this list and [`crate::image_index::MODEL`] when
/// the pinned model changes.
#[rustfmt::skip]
const VOCABULARY: &[&str] = &[
    "academic_dress", "accident_disaster", "accidental", "accordion", "acoustic_electric_guitar", "action_figure",
    "adolescent", "aerial_photography", "air_travel", "aircraft", "airliner", "airplane",
    "alcoholic_beverage", "american_football", "american_shorthair", "animal", "antelope", "antique_car",
    "apartment", "apple", "aquarium", "architecture", "army", "art",
    "audience", "audio_equipment", "australian_shepherd", "aviation", "baby", "backpack",
    "bad_framing", "bad_lighting", "bag", "baked_goods", "balcony", "ball_object",
    "balloon", "banana", "banner", "baseball_bat", "baseball_glove", "baseball_sport",
    "basket", "basketball_sport", "bathroom", "bathtub", "beach", "bear",
    "beard", "bed", "bee", "beer", "beetle", "belt",
    "bench", "berry", "bicycle", "bicycle_helmet", "billboard", "bird",
    "birthday", "birthday_cake", "black_and_white", "black_cat", "blazer", "blood_injury",
    "blossom", "blouse", "boat", "book", "bookcase", "boot",
    "border_collie", "bottle", "bouquet", "bowl", "bowling", "boxer",
    "boxing_ring", "boy", "bracelet", "brassiere", "bread", "brick",
    "bride", "bridge_structure", "bronze_sculpture", "building", "bull", "bulldog",
    "burmese", "bus", "bust", "butterfly", "cake", "camera",
    "canal", "candle", "candy", "cannon", "canoe", "cap",
    "car", "car_seat", "carpet", "carrot", "cartoon", "castle",
    "cat", "cattle", "cave", "cello", "cemetery", "chair",
    "chandelier", "chart_or_slide", "chess", "chest_of_drawers", "chicken", "child",
    "child_art", "chocolate", "christmas", "christmas_tree", "church", "city",
    "cityscape", "classic_car", "clock", "clothing", "cloud", "coast",
    "coat", "cocktail", "coffee_cup", "coffee_drink", "coffee_table", "coin",
    "common_sunflower", "computer", "computer_keyboard", "computer_monitor", "computer_mouse", "concert",
    "convenience_store", "cookie", "cosmetics", "costume", "couch", "cowboy_hat",
    "crab", "crane_machine", "cream_drink", "cross", "cross_country_running", "crowd",
    "crown", "cumulus", "cup", "cupboard", "cupcake", "curtain",
    "cycle_sport", "dance", "deer", "denim", "desk", "dessert",
    "dinosaur", "display_device", "distilled_beverage", "document", "dog", "doll",
    "dolphin", "door", "dragonfly", "drawing", "dress", "dress_shirt",
    "drink", "drum", "duck", "eagle", "earring", "egg",
    "elephant", "engine", "english_cocker_spaniel", "falcon", "fast_food", "fedora",
    "fence", "fictional_character", "field", "figurine", "fire", "fire_hydrant",
    "firefighter", "fireplace", "fireworks", "fish", "fixed_wing_aircraft", "flag",
    "flower", "flowerpot", "fog", "food", "football", "football_helmet",
    "footwear", "forest", "forgettable", "fork", "fountain", "french_fries",
    "fried_food", "frog", "fruit", "funeral", "furniture", "garden_roses",
    "gate", "giraffe", "girl", "glass", "glasses", "glove",
    "goat", "goggles", "golden_retriever", "golf", "goose", "gown",
    "graduation", "graffiti", "grape", "grass", "grassland", "grave",
    "grilling", "guitar", "guitarist", "gun", "halloween", "hamburger",
    "handbag", "handwriting", "harbor_seal", "hat", "headphones", "helicopter",
    "helmet", "high_heels", "hiking", "hill", "himalayan", "hockey",
    "home_appliance", "hoodie", "horizon", "horse", "horse_racing", "hot_air_balloon",
    "house", "houseplant", "human_face", "hut", "ice_cream", "ice_skating",
    "icing", "id_card", "identity_document", "illustration", "illustration_or_art", "insect",
    "jacket", "jeans", "jersey", "jet_aircraft", "jewellery", "juice",
    "jungle", "keeper", "kiss", "kitchen", "kitchen_appliance", "kitchen_dining_room_table",
    "knife", "labrador_retriever", "ladder", "lake", "lamp", "landmark",
    "landscape", "lantern", "laptop", "lavender_plant", "lawn", "leaf",
    "leaf_vegetable", "lego", "lemon_plant", "letter_message", "light_aircraft", "lighthouse",
    "lightning", "lily", "lion", "lipstick", "lizard", "loudspeaker",
    "low_content", "luggage_and_bags", "maine_coon", "man", "mannequin", "manx",
    "map", "maple", "marine_mammal", "mask", "meal", "meat",
    "mechanical_fan", "medical_hospital", "medical_reference", "meme_or_graphic", "menu", "metropolis",
    "metropolitan_area", "microphone", "military", "military_aircraft", "military_camouflage", "military_uniform",
    "mirror", "mobile_phone", "monkey", "monument", "moon", "moths_and_butterflies",
    "motorcycle", "motorsport", "mountain", "mountain_range", "moustache", "muffin",
    "mug", "mushroom", "music", "musical_ensemble", "musical_keyboard", "musician",
    "narrow_body_aircraft", "necklace", "neighbourhood", "newspaper", "norwegian_forest_cat", "nsfw_explicit",
    "nsfw_suggestive", "ocean", "office_building", "orange_fruit", "other", "outerwear",
    "overhead_power_line", "owl", "painting", "palm_tree", "parachute", "parrot",
    "pasta", "pastry", "pedestrian", "pen", "penguin", "performing_arts",
    "persian", "person", "personal_computer", "personal_flotation_device", "pet", "photo",
    "photo_of_screen", "piano", "picture_frame", "pig", "pizza", "plant",
    "plate", "playground", "podium", "pond", "poodle", "porch",
    "poster", "printed_circuit_board", "projection_screen", "public_transport", "pug", "pumpkin",
    "rabbit", "race_car", "racing", "racing_bicycle", "racket", "railroad_car",
    "railway", "rainbow", "rat", "receipt", "reef", "reference",
    "reference_photo", "refrigerator", "repair_reference", "reptile", "residential_area", "rifle",
    "river", "road", "rock", "rose", "rotated", "rottweiler",
    "ruins", "running", "sailboat", "salad", "sand", "sandal",
    "sandwich", "saxophone", "scarf", "scooter", "screenshot", "sculpture",
    "sea", "sea_lion", "seafood", "selfie", "senior_citizen", "shed",
    "sheep", "shellfish", "shih_tzu", "ship", "shirt", "shoe",
    "shopping_reference", "shore", "shorts", "shower", "shrub_plant", "siamese",
    "sidewalk", "single_lens_reflex_camera", "sink", "skateboard", "sketch", "ski",
    "skiing", "skirt", "skull", "sky", "skyline", "skyscraper",
    "smartphone", "smile", "snack", "snake", "sneakers", "snow",
    "snowboarding", "soccer", "sock", "sofa_bed", "soft_drink", "soil",
    "soldier", "sparrow", "speech", "spider", "spoon", "sports",
    "sports_car", "sports_uniform", "sports_venue", "squash_plant", "squirrel", "stadium",
    "stage", "stained_glass", "stairs", "statue", "steering_wheel", "stone_carving",
    "stool", "strawberry", "street", "street_light", "studio_couch", "stuffed_toy",
    "suit", "sun", "sun_hat", "sunglasses", "sunset", "supercar",
    "superhero", "surfboard", "surfing", "sushi", "swan", "sweater",
    "swimming", "swimming_pool", "swimwear", "t_shirt", "table", "tablet_computer",
    "tank", "taxi", "tea", "technical_flaw", "teddy_bear", "telephone",
    "television", "temple", "tennis", "tent", "test_or_duplicate_shot", "tie",
    "tiger", "toddler", "toilet", "tomato", "tortoise", "tower",
    "tower_block", "town", "toy", "track_and_field_athletics", "tractor", "traffic_light",
    "traffic_sign", "train", "tray", "tree", "tripod", "trousers",
    "truck", "trumpet", "turtle", "ultramarathon", "umbrella", "uniform",
    "unusable", "urban_area", "van", "vase", "vegetable", "vehicle",
    "vintage_car", "violence_protest", "violin", "volleyball_ball", "volleyball_sport", "walking",
    "walkway", "wall_clock", "waste_container", "watch", "water", "water_skiing",
    "watercraft", "waterfall", "wave_noun", "weapon", "wedding", "wedding_cake",
    "wedding_dress", "wheelchair", "whiteboard", "wilderness", "wildlife", "windmill",
    "window", "wine", "wine_bottle", "wine_glass", "woman", "zoo",
];

/// Words whose final `s` is not a plural, plus the irregulars that the suffix
/// rules would damage ("news" must never become "new"). Shared with the
/// private search app's inflection rules.
const INVARIANT: &[&str] = &[
    "news",
    "series",
    "species",
    "lens",
    "gas",
    "bias",
    "atlas",
    "canvas",
    "christmas",
    "jesus",
    "moses",
    "texas",
    "paris",
    "james",
    "thomas",
    "always",
    "perhaps",
    "this",
    "his",
    "its",
    "was",
    "has",
    "does",
    "is",
    "as",
    "us",
    "bus",
    "plus",
    "thus",
    "status",
    "virus",
    "census",
    "campus",
    "bonus",
    "focus",
    "corpus",
    "nexus",
    "analysis",
    "basis",
    "crisis",
    "thesis",
    "diagnosis",
    "physics",
    "mathematics",
    "maths",
    "economics",
    "politics",
    "electronics",
    "statistics",
    "ethics",
    "genesis",
    "exodus",
    "leviticus",
    "acts",
    "kings",
    "psalms",
    "proverbs",
    "corinthians",
    "galatians",
    "ephesians",
    "hebrews",
    "romans",
    "chaos",
    "cosmos",
    "glass",
    "class",
    "less",
    "address",
    "process",
    "access",
    "business",
    "express",
    "press",
    "wireless",
    "across",
    "progress",
    "success",
    "windows",
    "linux",
    "nixos",
    "kubernetes",
    "sms",
    "gps",
    "dns",
    "https",
    "aws",
    "ios",
    "macos",
    "tls",
    "cms",
    "rss",
    "css",
    "js",
    "during",
    "thing",
    "king",
    "ring",
    "spring",
    "string",
    "sing",
    "bring",
    "wing",
    "morning",
    "evening",
    "nothing",
    "something",
    "anything",
    "everything",
    "ceiling",
    "sibling",
    "wedding",
    "need",
    "seed",
    "feed",
    "speed",
    "bed",
    "red",
    "shed",
    "hundred",
    "sacred",
    "indeed",
];

/// Joins words inside compound tags; it never identifies a tag on its own.
const STOPWORDS: &[&str] = &[
    "a", "an", "and", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with",
];

/// Wording that names the same thing. Any member may stand for any other, so a
/// group only holds close meanings. Members that are also EYE tags become
/// matches; the rest are the words people actually type.
#[rustfmt::skip]
const FAMILIES: &[&[&str]] = &[
    &[
        "rock", "stone", "boulder", "pebble", "geology"
    ],
    &[
        "mountain", "hill", "peak", "summit", "ridge", "alps", "mountain_range"
    ],
    &[
        "forest", "woods", "woodland", "tree", "timber", "jungle"
    ],
    &[
        "water", "lake", "river", "stream", "creek", "pond", "canal", "waterway"
    ],
    &[
        "sea", "ocean", "wave", "surf"
    ],
    &[
        "beach", "sand", "coast", "shore", "seaside", "dune"
    ],
    &[
        "sky", "cloud", "cumulus", "overcast", "horizon"
    ],
    &[
        "sunset", "sunrise", "dusk", "dawn", "twilight", "golden_hour"
    ],
    &[
        "snow", "winter", "frost", "snowy"
    ],
    &[
        "fog", "mist", "haze", "foggy"
    ],
    &[
        "rain", "rainy", "rainfall", "storm", "lightning", "thunder"
    ],
    &[
        "field", "meadow", "pasture", "grass", "grassland", "lawn"
    ],
    &[
        "flower", "flowers", "bloom", "blossom", "floral"
    ],
    &[
        "plant", "plants", "houseplant", "shrub", "shrub_plant", "flowerpot", "planter"
    ],
    &[
        "cave", "cavern", "underground"
    ],
    &[
        "island", "isle", "reef", "coral", "atoll"
    ],
    &[
        "ruins", "ruin", "archaeology", "ancient", "historic_site"
    ],
    &[
        "castle", "fortress", "fort", "palace"
    ],
    &[
        "village", "town", "hamlet", "settlement", "neighbourhood"
    ],
    &[
        "city", "urban", "downtown", "metropolis", "metropolitan", "cityscape", "skyline",
        "urban_area", "metropolitan_area"
    ],
    &[
        "building", "buildings", "architecture", "structure", "facade"
    ],
    &[
        "street", "road", "avenue", "lane", "highway", "sidewalk", "pedestrian", "walkway"
    ],
    &[
        "bridge", "overpass", "viaduct", "bridge_structure"
    ],
    &[
        "wilderness", "wild", "nature", "natural", "outdoors", "countryside", "landscape"
    ],
    &[
        "person", "people", "human", "humans", "figure"
    ],
    &[
        "man", "men", "male", "guy", "gentleman"
    ],
    &[
        "woman", "women", "female", "lady"
    ],
    &[
        "child", "children", "kid", "kids", "youngster"
    ],
    &[
        "baby", "infant", "newborn", "toddler"
    ],
    &[
        "boy", "boys", "lad"
    ],
    &[
        "girl", "girls"
    ],
    &[
        "adolescent", "teen", "teenager", "youth"
    ],
    &[
        "senior_citizen", "senior", "elderly", "pensioner", "old_person"
    ],
    &[
        "crowd", "audience", "spectators"
    ],
    &[
        "face", "human_face", "head", "headshot"
    ],
    &[
        "selfie", "self_portrait"
    ],
    &[
        "smile", "smiling", "grin", "laughing"
    ],
    &[
        "beard", "bearded", "moustache", "facial_hair"
    ],
    &[
        "wedding", "bride", "groom", "marriage", "married", "nuptial"
    ],
    &[
        "dog", "dogs", "puppy", "canine", "doggy", "pet", "pets", "golden_retriever", "retriever",
        "labrador", "labrador_retriever", "poodle", "bulldog", "pug", "shih_tzu", "spaniel",
        "english_cocker_spaniel", "collie", "border_collie", "australian_shepherd", "rottweiler",
        "mutt", "hound"
    ],
    &[
        "cat", "cats", "kitten", "kitty", "feline", "siamese", "persian", "burmese", "maine_coon",
        "norwegian_forest_cat", "american_shorthair", "manx", "black_cat"
    ],
    &[
        "duck", "ducks", "goose", "geese", "swan", "swans"
    ],
    &[
        "horse", "horses", "pony", "equine", "stallion", "mare"
    ],
    &[
        "cattle", "cow", "cows", "bull", "ox", "bovine", "livestock"
    ],
    &[
        "goat", "goats", "sheep", "lamb", "farm_animal"
    ],
    &[
        "wildlife", "animal", "animals", "creature", "fauna"
    ],
    &[
        "bee", "bees", "beetle", "beetles", "dragonfly", "insect", "insects", "bug", "bugs"
    ],
    &[
        "butterfly", "butterflies", "moth", "moths", "moths_and_butterflies"
    ],
    &[
        "spider", "spiders", "arachnid", "web"
    ],
    &[
        "fish", "fishes", "aquarium", "marine_life"
    ],
    &[
        "reptile", "reptiles", "lizard", "lizards", "snake", "snakes", "turtle", "turtles",
        "tortoise", "frog", "frogs", "amphibian"
    ],
    &[
        "marine_mammal", "sea_lion", "dolphin", "dolphins", "whale", "whales", "seal", "seals",
        "harbor_seal", "walrus"
    ],
    &[
        "deer", "stag", "doe", "elk", "moose", "antelope"
    ],
    &[
        "rabbit", "bunny", "hare", "rabbits", "rodent"
    ],
    &[
        "squirrel", "squirrels"
    ],
    &[
        "monkey", "monkeys", "ape", "primate", "gorilla", "chimpanzee"
    ],
    &[
        "food", "meal", "dish", "cuisine", "cooking", "cooked", "dinner", "lunch", "breakfast",
        "supper"
    ],
    &[
        "fast_food", "burger", "hamburger", "fries", "french_fries", "takeaway", "takeout"
    ],
    &[
        "seafood", "shellfish", "crab", "lobster", "oyster", "prawn", "shrimp"
    ],
    &[
        "salad", "greens", "veggie", "veg"
    ],
    &[
        "fruit", "fruits"
    ],
    &[
        "vegetable", "vegetables"
    ],
    &[
        "cake", "cakes", "birthday_cake", "wedding_cake", "cupcake", "cupcakes"
    ],
    &[
        "dessert", "sweets", "sweet", "pastry", "pastries", "cookie", "cookies", "biscuit",
        "muffin", "muffins", "chocolate", "candy", "ice_cream", "icing"
    ],
    &[
        "bread", "bakery", "baked_goods", "loaf", "toast"
    ],
    &[
        "coffee", "espresso", "latte", "cappuccino", "coffee_drink", "coffee_cup", "mug"
    ],
    &[
        "tea", "teacup", "herbal_tea", "cup"
    ],
    &[
        "beer", "ale", "lager", "pint", "brewery"
    ],
    &[
        "wine", "wine_glass", "wine_bottle", "vino", "red_wine", "white_wine"
    ],
    &[
        "cocktail", "cocktails", "mixed_drink", "martini", "mojito"
    ],
    &[
        "drink", "drinks", "beverage", "beverages", "refreshment"
    ],
    &[
        "soft_drink", "soda", "cola", "lemonade", "juice"
    ],
    &[
        "bottle", "bottled_water", "water_bottle"
    ],
    &[
        "pizza", "pizzas", "slice"
    ],
    &[
        "pasta", "spaghetti", "noodles", "lasagna"
    ],
    &[
        "sandwich", "sandwiches", "sub", "wrap"
    ],
    &[
        "sushi", "sashimi", "maki"
    ],
    &[
        "grilling", "barbecue", "bbq", "grill", "steak", "meat"
    ],
    &[
        "snack", "snacks", "chips", "crisps", "popcorn"
    ],
    &[
        "car", "cars", "automobile", "auto", "vehicle", "motorcar"
    ],
    &[
        "sports_car", "supercar", "race_car", "racing_car", "classic_car", "vintage_car",
        "antique_car", "hot_rod"
    ],
    &[
        "truck", "trucks", "lorry", "pickup", "semi"
    ],
    &[
        "van", "vans", "minivan", "campervan"
    ],
    &[
        "bicycle", "bike", "bikes", "pushbike"
    ],
    &[
        "motorcycle", "motorbike", "scooter", "moped", "biker"
    ],
    &[
        "train", "trains", "railway", "railroad", "locomotive", "rail", "railroad_car"
    ],
    &[
        "bus", "buses", "coach", "public_transport"
    ],
    &[
        "aircraft", "airplane", "aeroplane", "plane", "planes", "aviation", "jet", "jets"
    ],
    &[
        "helicopter", "chopper", "rotorcraft"
    ],
    &[
        "boat", "boats", "ship", "ships", "vessel", "watercraft", "sailboat", "yacht", "canoe"
    ],
    &[
        "sailing", "sail", "sailboat", "yacht"
    ],
    &[
        "surfing", "surfboard", "surfer", "surf"
    ],
    &[
        "tractor", "farm_machinery", "agriculture"
    ],
    &[
        "fire_engine", "fire_truck", "firefighter", "fire_hydrant"
    ],
    &[
        "computer", "computers", "pc", "desktop", "personal_computer"
    ],
    &[
        "laptop", "laptops", "notebook", "macbook"
    ],
    &[
        "phone", "phones", "mobile_phone", "smartphone", "cellphone", "iphone", "android"
    ],
    &[
        "tablet", "tablet_computer", "ipad"
    ],
    &[
        "television", "tv", "telly", "screen", "display_device", "computer_monitor"
    ],
    &[
        "camera", "cameras", "photography", "photographer", "dslr", "single_lens_reflex_camera"
    ],
    &[
        "keyboard", "computer_keyboard", "typing"
    ],
    &[
        "mouse", "computer_mouse"
    ],
    &[
        "headphones", "earphones", "headset", "audio_equipment"
    ],
    &[
        "speaker", "loudspeaker", "sound_system", "stereo"
    ],
    &[
        "microphone", "mic", "microphones"
    ],
    &[
        "guitar", "guitars", "electric_guitar", "acoustic_electric_guitar", "guitarist"
    ],
    &[
        "piano", "pianos", "keyboard_instrument", "musical_keyboard"
    ],
    &[
        "violin", "violins", "cello", "viola", "strings"
    ],
    &[
        "drum", "drums", "drummer", "percussion"
    ],
    &[
        "saxophone", "trumpet", "accordion", "brass", "woodwind"
    ],
    &[
        "music", "musical", "song", "band", "musician", "musical_ensemble"
    ],
    &[
        "concert", "concerts", "gig", "live_music", "festival"
    ],
    &[
        "book", "books", "reading", "novel", "literature"
    ],
    &[
        "newspaper", "news", "paper", "press"
    ],
    &[
        "letter", "letter_message", "mail", "envelope", "handwriting"
    ],
    &[
        "map", "maps", "cartography", "atlas"
    ],
    &[
        "document", "documents", "paperwork", "scan", "scanned_document"
    ],
    &[
        "receipt", "receipts", "invoice", "bill", "till_receipt"
    ],
    &[
        "id_card", "identity_document", "passport", "licence", "license", "driver_licence"
    ],
    &[
        "whiteboard", "white_board", "marker_board"
    ],
    &[
        "chart_or_slide", "chart", "graph", "slide", "diagram", "infographic"
    ],
    &[
        "screenshot", "screenshots", "screen_capture", "screen_grab", "screen_shot"
    ],
    &[
        "photo_of_screen", "screen_photo", "monitor_photo"
    ],
    &[
        "meme_or_graphic", "meme", "memes", "graphic"
    ],
    &[
        "cartoon", "cartoons", "animation", "animated", "comic", "comics"
    ],
    &[
        "art", "artwork", "painting", "paintings", "painter"
    ],
    &[
        "drawing", "drawings", "sketch", "sketches", "illustration", "illustrations"
    ],
    &[
        "graffiti", "street_art", "mural", "tagging"
    ],
    &[
        "sculpture", "statue", "statues", "sculptures", "stone_carving", "bronze_sculpture",
        "bust", "figurine"
    ],
    &[
        "poster", "posters", "flyer", "billboard", "banner"
    ],
    &[
        "traffic_sign", "sign", "signage", "street_sign", "traffic_light"
    ],
    &[
        "furniture", "chair", "chairs", "table", "tables", "desk", "desks"
    ],
    &[
        "couch", "sofa", "sofa_bed", "studio_couch", "settee", "lounge"
    ],
    &[
        "bed", "beds", "bedroom", "mattress"
    ],
    &[
        "kitchen", "kitchen_appliance", "kitchen_dining_room_table", "cooking_area", "pantry"
    ],
    &[
        "home_appliance", "appliance", "appliances", "refrigerator", "fridge", "washing_machine"
    ],
    &[
        "toy", "toys", "plaything", "playroom"
    ],
    &[
        "lego", "legos", "lego_brick", "building_blocks"
    ],
    &[
        "doll", "dolls", "action_figure", "figurine", "stuffed_toy", "teddy_bear", "plush"
    ],
    &[
        "balloon", "balloons", "party_balloon"
    ],
    &[
        "christmas", "xmas", "christmas_tree", "festive", "holiday_season"
    ],
    &[
        "halloween", "pumpkin", "pumpkins", "jack_o_lantern", "spooky"
    ],
    &[
        "fireworks", "firework", "pyrotechnics", "sparkler"
    ],
    &[
        "candle", "candles", "candlelight", "lantern"
    ],
    &[
        "clock", "clocks", "timepiece", "wall_clock"
    ],
    &[
        "jewellery", "jewelry", "necklace", "earring", "earrings", "bracelet", "bracelets",
        "ring", "rings"
    ],
    &[
        "glasses", "eyeglasses", "spectacles", "sunglasses", "goggles"
    ],
    &[
        "clothing", "clothes", "outfit", "garment", "apparel", "attire"
    ],
    &[
        "shirt", "shirts", "t_shirt", "tshirt", "tee", "blouse", "dress_shirt"
    ],
    &[
        "trousers", "pants", "jeans", "shorts", "skirt", "leggings"
    ],
    &[
        "dress", "dresses", "gown", "frock"
    ],
    &[
        "jacket", "jackets", "coat", "coats", "outerwear", "parka"
    ],
    &[
        "sweater", "sweaters", "jumper", "hoodie", "cardigan", "knitwear"
    ],
    &[
        "suit", "suits", "blazer", "tuxedo"
    ],
    &[
        "shoes", "shoe", "sneakers", "trainers", "footwear", "boot", "boots", "sandal", "sandals",
        "high_heels"
    ],
    &[
        "hat", "hats", "cap", "caps", "beanie", "fedora", "cowboy_hat", "sun_hat", "helmet"
    ],
    &[
        "bag", "bags", "handbag", "backpack", "purse", "luggage", "luggage_and_bags"
    ],
    &[
        "umbrella", "umbrellas", "parasol"
    ],
    &[
        "watch", "watches", "wristwatch", "smartwatch"
    ],
    &[
        "mask", "masks", "face_mask", "costume_mask"
    ],
    &[
        "costume", "costumes", "fancy_dress"
    ],
    &[
        "uniform", "uniforms", "sports_uniform", "military_uniform", "jersey"
    ],
    &[
        "grave", "graves", "gravestone", "cemetery", "tombstone", "headstone", "memorial"
    ],
    &[
        "fence", "fences", "picket_fence", "railing"
    ],
    &[
        "stairs", "staircase", "steps", "stairway"
    ],
    &[
        "door", "doors", "doorway", "entrance", "gate"
    ],
    &[
        "window", "windows", "windshield"
    ],
    &[
        "wall", "walls", "brick", "brick_wall", "masonry"
    ],
    &[
        "tower", "towers", "tower_block", "clock_tower", "spire"
    ],
    &[
        "lighthouse", "lighthouses", "beacon"
    ],
    &[
        "windmill", "windmills", "turbine", "wind_turbine"
    ],
    &[
        "stadium", "arena", "sports_venue", "playing_field"
    ],
    &[
        "playground", "playgrounds", "park", "swing", "slide"
    ],
    &[
        "pool", "swimming_pool", "paddling_pool"
    ],
    &[
        "bathroom", "bath", "bathtub", "shower", "toilet", "washroom"
    ],
    &[
        "shop", "store", "shopping", "retail", "market", "supermarket", "convenience_store"
    ],
    &[
        "church", "churches", "cathedral", "chapel", "worship"
    ],
    &[
        "temple", "temples", "shrine", "monastery", "pagoda"
    ],
    &[
        "stage", "theatre", "theater", "performance", "performing_arts", "show"
    ],
    &[
        "podium", "lectern", "speech"
    ],
    &[
        "sport", "sports", "athletics", "athlete", "competition"
    ],
    &[
        "soccer", "footy", "soccer_ball"
    ],
    &[
        "american_football", "nfl", "gridiron", "football"
    ],
    &[
        "basketball", "basketball_sport", "basketball_ball", "hoops"
    ],
    &[
        "tennis", "racket"
    ],
    &[
        "baseball", "baseball_sport", "baseball_glove", "baseball_bat"
    ],
    &[
        "hockey", "ice_hockey", "puck", "hockey_stick"
    ],
    &[
        "boxing", "boxer", "boxing_ring", "prizefight"
    ],
    &[
        "bowling", "bowling_ball", "bowling_pin", "ten_pin"
    ],
    &[
        "golf", "golfer", "golf_club", "golf_course"
    ],
    &[
        "skiing", "ski", "skier", "snowboarding", "snowboard"
    ],
    &[
        "skating", "ice_skating", "roller_skating"
    ],
    &[
        "running", "jogging", "jog", "runner", "marathon", "ultramarathon",
        "cross_country_running", "track_and_field_athletics"
    ],
    &[
        "hiking", "hike", "hiker", "trekking", "walking", "walk"
    ],
    &[
        "swimming", "swimmer", "swim", "water_skiing", "water_polo"
    ],
    &[
        "cycling", "cyclist", "bicycle_race", "cycle_sport", "racing_bicycle"
    ],
    &[
        "dance", "dancing", "dancer", "ballet", "ballroom"
    ],
    &[
        "camping", "campsite", "tent", "tents", "campfire"
    ],
    &[
        "reflection", "mirror", "mirrored", "reflected"
    ],
    &[
        "black_and_white", "monochrome", "grayscale", "greyscale"
    ],
    &[
        "sunny", "sunshine", "sun", "sunlight"
    ],
    &[
        "reference_photo", "reference", "reference_image", "sample"
    ],
    &[
        "test_or_duplicate_shot", "test_shot", "duplicate", "duplicates"
    ],
    &[
        "accidental", "accident_shot", "pocket_shot", "by_mistake"
    ],
    &[
        "low_content", "boring", "featureless"
    ],
];

/// One-way links from typed wording to the tags a scene usually carries.
/// Searching the head widens; searching a target does not, so "rock" can reach
/// mountain photos without making every mountain search include rocks.
#[rustfmt::skip]
const ASSOCIATIONS: &[(&str, &[&str])] = &[
    (
        "rock",
        &[
            "mountain", "cave", "stone_carving", "ruins"
        ],
    ),
    (
        "mountain",
        &[
            "hiking", "landscape", "snow", "forest", "wilderness"
        ],
    ),
    (
        "forest",
        &[
            "tree", "wilderness", "hiking", "shrub_plant"
        ],
    ),
    (
        "beach",
        &[
            "swimming", "surfing", "sand", "sunset", "palm_tree"
        ],
    ),
    (
        "sunset",
        &[
            "sky", "horizon", "beach", "ocean"
        ],
    ),
    (
        "sky",
        &[
            "cloud", "sunset", "horizon"
        ],
    ),
    (
        "hiking",
        &[
            "mountain", "forest", "backpack", "wilderness"
        ],
    ),
    (
        "climbing",
        &[
            "mountain", "rock", "hiking", "backpack"
        ],
    ),
    (
        "garden",
        &[
            "garden_roses", "houseplant", "shrub_plant", "lawn", "flowerpot", "common_sunflower"
        ],
    ),
    (
        "desert",
        &[
            "sand", "wilderness", "soil"
        ],
    ),
    (
        "pet",
        &[
            "dog", "cat"
        ],
    ),
    (
        "bird",
        &[
            "duck", "goose", "swan", "eagle", "falcon", "owl", "parrot", "sparrow", "penguin",
            "chicken"
        ],
    ),
    (
        "safari",
        &[
            "elephant", "giraffe", "lion", "antelope"
        ],
    ),
    (
        "zoo",
        &[
            "elephant", "giraffe", "lion", "monkey", "tiger"
        ],
    ),
    (
        "fruit",
        &[
            "apple", "banana", "orange_fruit", "strawberry", "grape", "berry", "lemon_plant"
        ],
    ),
    (
        "vegetable",
        &[
            "tomato", "carrot", "leaf_vegetable", "squash_plant", "mushroom"
        ],
    ),
    (
        "restaurant",
        &[
            "food", "meal", "wine_glass", "coffee_cup"
        ],
    ),
    (
        "market",
        &[
            "convenience_store", "food", "fruit", "vegetable"
        ],
    ),
    (
        "wedding",
        &[
            "bride", "wedding_dress", "wedding_cake", "bouquet", "church"
        ],
    ),
    (
        "christmas",
        &[
            "christmas_tree", "snow", "candle", "fireplace"
        ],
    ),
    (
        "halloween",
        &[
            "pumpkin", "candle", "costume"
        ],
    ),
    (
        "birthday",
        &[
            "birthday_cake", "cupcake", "candle", "balloon"
        ],
    ),
    (
        "party",
        &[
            "balloon", "cake", "crowd", "wine_glass"
        ],
    ),
    (
        "concert",
        &[
            "stage", "microphone", "audience", "guitarist", "musician", "loudspeaker"
        ],
    ),
    (
        "portrait",
        &[
            "human_face", "selfie", "person"
        ],
    ),
    (
        "family",
        &[
            "person", "child", "baby", "man", "woman"
        ],
    ),
    (
        "museum",
        &[
            "art", "painting", "statue", "sculpture"
        ],
    ),
    (
        "hospital",
        &[
            "medical_hospital"
        ],
    ),
    (
        "school",
        &[
            "child", "bus", "playground"
        ],
    ),
    (
        "office",
        &[
            "desk", "computer", "laptop", "office_building", "chair"
        ],
    ),
    (
        "computer",
        &[
            "desk", "computer_keyboard", "personal_computer", "computer_mouse", "office_building"
        ],
    ),
    (
        "kitchen",
        &[
            "food", "meal", "kitchen_appliance", "refrigerator"
        ],
    ),
    (
        "coffee",
        &[
            "mug", "coffee_cup", "coffee_table"
        ],
    ),
    (
        "book",
        &[
            "bookcase", "coffee_table"
        ],
    ),
    (
        "car",
        &[
            "road", "steering_wheel", "car_seat", "street"
        ],
    ),
    (
        "vehicle",
        &[
            "car", "truck", "van", "motorcycle", "bicycle", "bus", "train", "aircraft", "boat"
        ],
    ),
    (
        "airport",
        &[
            "aircraft", "airplane", "airliner", "jet_aircraft", "aviation"
        ],
    ),
    (
        "aquarium",
        &[
            "fish", "tank", "marine_mammal"
        ],
    ),
    (
        "farm",
        &[
            "cattle", "tractor", "field", "shed", "hut"
        ],
    ),
    (
        "fishing",
        &[
            "water", "boat", "fish"
        ],
    ),
    (
        "park",
        &[
            "playground", "grass", "tree", "walking"
        ],
    ),
    (
        "gym",
        &[
            "boxing_ring", "running"
        ],
    ),
    (
        "military",
        &[
            "tank", "military_uniform", "military_camouflage", "military_aircraft"
        ],
    ),
    (
        "holiday",
        &[
            "beach", "mountain", "airplane", "palm_tree", "sunset"
        ],
    ),
    (
        "night",
        &[
            "moon", "street_light", "cityscape", "fireworks", "lightning"
        ],
    ),
    (
        "document",
        &[
            "receipt", "letter_message", "identity_document", "newspaper", "menu", "map",
            "whiteboard"
        ],
    ),
    (
        "screenshot",
        &[
            "computer_monitor", "display_device", "photo_of_screen"
        ],
    ),
    (
        "selfie",
        &[
            "human_face"
        ],
    ),
    (
        "shadow",
        &[
            "black_and_white"
        ],
    ),
    (
        "fireworks",
        &[
            "sky", "cityscape"
        ],
    ),
    (
        "moon",
        &[
            "sky"
        ],
    ),
    (
        "lighthouse",
        &[
            "coast", "sea", "ocean", "rock"
        ],
    ),
    (
        "food",
        &[
            "table", "plate", "kitchen_dining_room_table", "meal"
        ],
    ),
    (
        "flower",
        &[
            "garden_roses", "common_sunflower", "bouquet", "blossom", "lavender_plant"
        ],
    ),
    (
        "snow",
        &[
            "skiing", "snowboarding"
        ],
    ),
    (
        "dog",
        &[
            "grass", "walking"
        ],
    ),
];

/// Lowercase EYE-style identifier for typing such as `Rocks`, `T-shirts`,
/// `personal computer` or `rock's`. Apostrophes join the word (`rocks`) while
/// other punctuation separates words (`t_shirt`). The result is empty when the
/// text has no letters or digits.
pub(crate) fn normalize(term: &str) -> String {
    let mut normalized = String::new();
    let mut separator = false;
    for character in term.trim().chars() {
        if character.is_ascii_alphanumeric() {
            if separator && !normalized.is_empty() && normalized.len() < 95 {
                normalized.push('_');
            }
            separator = false;
            if normalized.len() < 96 {
                normalized.push(character.to_ascii_lowercase());
            }
        } else if matches!(character, '\'' | '\u{2019}' | '`') {
            // Possessives read as the plain word; "rock's" means "rocks".
        } else if !normalized.is_empty() {
            separator = true;
        }
        if normalized.len() >= 96 {
            break;
        }
    }
    normalized
}

fn identifier(word: &str) -> bool {
    (3..=96).contains(&word.len())
        && word
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

fn is_vowel(byte: u8) -> bool {
    matches!(byte, b'a' | b'e' | b'i' | b'o' | b'u')
}

fn push_form(forms: &mut Vec<String>, original: &str, candidate: String) {
    if candidate.len() >= 3 && candidate != original && !forms.contains(&candidate) {
        forms.push(candidate);
    }
}

/// The singular of a plural noun, keeping compounds intact.
fn singular_forms(word: &str) -> Vec<String> {
    let mut forms = Vec::new();
    if !identifier(word) || INVARIANT.contains(&word) {
        return forms;
    }
    let length = word.len();
    let stem = |cut: usize| word[..length - cut].to_string();
    if length > 4 && word.ends_with("ies") {
        push_form(&mut forms, word, format!("{}y", stem(3)));
    } else if length > 4 && word.ends_with("ves") {
        push_form(&mut forms, word, format!("{}f", stem(3)));
        push_form(&mut forms, word, format!("{}fe", stem(3)));
        push_form(&mut forms, word, stem(1));
    } else if length > 4 && (word.ends_with("xes") || word.ends_with("shes")) {
        push_form(&mut forms, word, stem(2));
    } else if length > 4
        && (word.ends_with("ses") || word.ends_with("zes") || word.ends_with("ches"))
    {
        push_form(&mut forms, word, stem(2));
        // "houses", "sizes", "caches": the singular keeps its final e.
        push_form(&mut forms, word, stem(1));
    } else if length > 3
        && word.ends_with('s')
        && !word.ends_with("ss")
        && !word.ends_with("us")
        && !word.ends_with("is")
    {
        push_form(&mut forms, word, stem(1));
    }
    forms
}

/// The stem of an `-ing` or `-ed` verb form.
fn verb_stems(word: &str) -> Vec<String> {
    let mut forms = Vec::new();
    if !identifier(word) || INVARIANT.contains(&word) {
        return forms;
    }
    let length = word.len();
    let stem = |cut: usize| word[..length - cut].to_string();
    if length > 5 && word.ends_with("ing") {
        let base = stem(3);
        let base_bytes = base.as_bytes();
        let last = base_bytes[base_bytes.len() - 1];
        if base_bytes.len() >= 3 && last == base_bytes[base_bytes.len() - 2] && !is_vowel(last) {
            // running -> run; filling -> fill stays available below.
            push_form(&mut forms, word, base[..base.len() - 1].to_string());
        }
        push_form(&mut forms, word, base.clone());
        push_form(&mut forms, word, format!("{}e", base));
    } else if length > 4 && word.ends_with("ied") {
        push_form(&mut forms, word, format!("{}y", stem(3)));
    } else if length >= 4 && word.ends_with("ed") {
        let base = stem(2);
        let base_bytes = base.as_bytes();
        let last = base_bytes[base_bytes.len() - 1];
        if base_bytes.len() >= 3 && last == base_bytes[base_bytes.len() - 2] && !is_vowel(last) {
            push_form(&mut forms, word, base[..base.len() - 1].to_string());
        }
        push_form(&mut forms, word, base);
        push_form(&mut forms, word, stem(1));
    }
    forms
}

/// Longer forms of a base word: its plural and its `-ing`/`-ed` verb forms.
fn extended_forms(word: &str) -> Vec<String> {
    let mut forms = Vec::new();
    if !identifier(word) || INVARIANT.contains(&word) {
        return forms;
    }
    let bytes = word.as_bytes();
    let length = word.len();
    let last = bytes[length - 1];
    let before = bytes[length - 2];
    // An inflected word already has its base in `singular_forms`.
    if (word.ends_with('s') && !word.ends_with("ss"))
        || word.ends_with("ing")
        || word.ends_with("ed")
    {
        return forms;
    }
    if last == b'y' && !is_vowel(before) {
        push_form(&mut forms, word, format!("{}ies", &word[..length - 1]));
    } else if matches!(last, b'x' | b'z') || word.ends_with("ch") || word.ends_with("sh") {
        push_form(&mut forms, word, format!("{}es", word));
    } else {
        push_form(&mut forms, word, format!("{}s", word));
    }
    if last == b'e' {
        push_form(&mut forms, word, format!("{}ing", &word[..length - 1]));
        push_form(&mut forms, word, format!("{}d", word));
    } else if last == b'y' && !is_vowel(before) {
        push_form(&mut forms, word, format!("{}ing", word));
        push_form(&mut forms, word, format!("{}ied", &word[..length - 1]));
    } else {
        push_form(&mut forms, word, format!("{}ing", word));
        push_form(&mut forms, word, format!("{}ed", word));
    }
    forms
}

/// Every grammatical form worth trying for one word, most reliable first.
pub(crate) fn forms(word: &str) -> Vec<String> {
    let mut forms = singular_forms(word);
    for form in extended_forms(word) {
        if !forms.contains(&form) {
            forms.push(form);
        }
    }
    forms
}

/// Shortest plausible stem, used to compare a typed word with a tag's own
/// words ("butterflies" and "butterfly" are the same word here).
fn base_form(word: &str) -> String {
    let mut stems = singular_forms(word);
    stems.extend(verb_stems(word));
    stems
        .into_iter()
        .filter(|form| form.len() >= 4)
        .min_by_key(String::len)
        .unwrap_or_else(|| word.to_string())
}

fn same_word(token: &str, term: &str) -> bool {
    base_form(token) == base_form(term)
        || forms(token).iter().any(|form| form == term)
        || forms(term).iter().any(|form| form == token)
}

/// Candidate tags for one normalised term.
fn candidates(term: &str, related: bool) -> Vec<String> {
    let mut tags = Vec::new();
    let mut add = |tag: &str| {
        if tags.len() < MAX_CANDIDATES && !tag.is_empty() && !tags.iter().any(|s| s == tag) {
            tags.push(tag.to_string());
        }
    };
    add(term);
    for form in forms(term) {
        add(&form);
    }
    if !term.contains('_') && term.len() >= 3 && !STOPWORDS.contains(&term) {
        for tag in VOCABULARY {
            if tag.split('_').any(|token| same_word(token, term)) {
                add(tag);
            }
        }
    }
    if related {
        for tag in related_tags(term) {
            add(tag);
        }
    }
    tags
}

/// Tags related to the term by wording, not by grammar. Never transitive, so a
/// search cannot drift away from what the user typed.
fn related_tags(term: &str) -> Vec<&'static str> {
    let mut keys = vec![term.to_string()];
    keys.extend(forms(term));
    let mut tags: Vec<&'static str> = Vec::new();
    for family in FAMILIES {
        if keys.iter().any(|key| family.contains(&key.as_str())) {
            for member in *family {
                add_vocabulary(&mut tags, member);
            }
        }
    }
    for (head, linked) in ASSOCIATIONS {
        if keys.iter().any(|key| key == head) {
            for member in *linked {
                add_vocabulary(&mut tags, member);
            }
        }
    }
    tags
}

fn add_vocabulary(tags: &mut Vec<&'static str>, member: &'static str) {
    if VOCABULARY.binary_search(&member).is_ok() && !tags.contains(&member) {
        tags.push(member);
    }
}

/// Matched tags for one typed term, for the browser to explain a widened
/// result without listing every candidate.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TagMatch {
    pub(crate) term: String,
    pub(crate) tags: Vec<String>,
}

pub(crate) struct TermPlan {
    pub(crate) term: String,
    pub(crate) tags: Vec<String>,
}

/// One candidate group per typed term. The groups are what SQL binds; keeping
/// them separate is what preserves "all tags" semantics after widening.
pub(crate) struct Plan {
    pub(crate) terms: Vec<TermPlan>,
}

impl Plan {
    /// JSON `[["rock","stone"],["beach"]]` for `json_each` in the search query.
    pub(crate) fn groups(&self) -> String {
        serde_json::to_string(&self.terms.iter().map(|term| &term.tags).collect::<Vec<_>>())
            .expect("candidate tags are valid JSON")
    }

    /// JSON array of every candidate, for one indexed lookup or sort.
    pub(crate) fn flat(&self) -> String {
        let tags: BTreeSet<&str> = self
            .terms
            .iter()
            .flat_map(|term| term.tags.iter().map(String::as_str))
            .collect();
        serde_json::to_string(&tags.into_iter().collect::<Vec<_>>())
            .expect("candidate tags are valid JSON")
    }

    /// Decision tags keep the spelling their owner saved. Attach the raw tag
    /// when its normalised form is already a candidate for the term, so one
    /// comma-separated search still finds both kinds of tag.
    pub(crate) fn attach_decision_tags(&mut self, tags: &[String]) {
        for term in &mut self.terms {
            for tag in tags {
                if term.tags.len() >= MAX_CANDIDATES * 2 {
                    break;
                }
                if term.tags.iter().any(|candidate| candidate == tag) {
                    continue;
                }
                let normalized = normalize(tag);
                if !normalized.is_empty() && term.tags.contains(&normalized) {
                    term.tags.push(tag.clone());
                }
            }
        }
    }

    /// Terms whose matched tags added something beyond the typed word, so the
    /// browser can show why an unlabelled-looking photo appeared.
    pub(crate) fn report(&self, present: &BTreeSet<String>) -> Vec<TagMatch> {
        self.terms
            .iter()
            .filter_map(|term| {
                let mut tags: Vec<String> = term
                    .tags
                    .iter()
                    .filter(|tag| present.contains(*tag))
                    .cloned()
                    .collect();
                tags.sort();
                tags.dedup();
                if tags.is_empty() || tags.iter().all(|tag| *tag == term.term) {
                    return None;
                }
                tags.truncate(MAX_REPORTED_TAGS);
                Some(TagMatch {
                    term: term.term.clone(),
                    tags,
                })
            })
            .take(MAX_REPORTED_TERMS)
            .collect()
    }
}

/// Build the candidate groups for normalised search terms. Later duplicates of
/// the same term reuse the first group.
pub(crate) fn plan(terms: &[String], related: bool) -> Plan {
    let mut groups = Plan { terms: Vec::new() };
    for term in terms.iter().take(MAX_TERMS) {
        let term = normalize(term);
        if term.is_empty() || groups.terms.iter().any(|group| group.term == term) {
            continue;
        }
        let tags = candidates(&term, related);
        groups.terms.push(TermPlan { term, tags });
    }
    groups
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidates_for(typed: &str, related: bool) -> Vec<String> {
        plan(&[typed.to_string()], related).terms.remove(0).tags
    }

    #[test]
    fn typed_plurals_case_and_spacing_reach_the_saved_tag() {
        for typed in ["rocks", "Rocks", "rock's", " ROCK "] {
            assert!(
                candidates_for(typed, false).iter().any(|tag| tag == "rock"),
                "{typed} must reach the saved rock tag"
            );
        }
        assert!(candidates_for("personal computer", false)
            .iter()
            .any(|tag| tag == "personal_computer"));
        assert!(candidates_for("T-shirts", false)
            .iter()
            .any(|tag| tag == "t_shirt"));
    }

    #[test]
    fn one_typed_word_reaches_compound_vocabulary_tags() {
        assert!(candidates_for("butterfly", false)
            .iter()
            .any(|tag| tag == "moths_and_butterflies"));
        assert!(candidates_for("sunflowers", false)
            .iter()
            .any(|tag| tag == "common_sunflower"));
    }

    #[test]
    fn related_wording_is_optional_bounded_and_not_transitive() {
        let related = candidates_for("woods", true);
        assert!(related.iter().any(|tag| tag == "forest"));
        assert!(related.iter().any(|tag| tag == "tree"));
        assert!(!candidates_for("woods", false)
            .iter()
            .any(|tag| tag == "forest"));
        assert!(candidates_for("dog", true)
            .iter()
            .any(|tag| tag == "golden_retriever"));
        // "forest" may reach hiking through its own association, but a word
        // reached from "woods" must not pull in that word's associations.
        assert!(!related.iter().any(|tag| tag == "camping"));
        assert!(related.len() <= MAX_CANDIDATES);
    }

    #[test]
    fn report_names_only_the_added_tags() {
        let plan = plan(&["rocks".to_string(), "beach".to_string()], true);
        let present = ["rock".to_string(), "beach".to_string()]
            .into_iter()
            .collect::<BTreeSet<_>>();
        let report = plan.report(&present);
        assert_eq!(report.len(), 1);
        assert_eq!(report[0].term, "rocks");
        assert_eq!(report[0].tags, vec!["rock".to_string()]);
    }

    #[test]
    fn decision_tags_keep_their_own_spelling() {
        let mut plan = plan(&["woods".to_string()], true);
        plan.attach_decision_tags(&["Forest".to_string(), "to be deleted".to_string()]);
        let tags = &plan.terms[0].tags;
        assert!(tags.iter().any(|tag| tag == "Forest"));
        assert!(!tags.iter().any(|tag| tag == "to be deleted"));
    }

    #[test]
    fn vocabulary_and_relations_stay_normalised_and_honest() {
        assert!(VOCABULARY.windows(2).all(|pair| pair[0] < pair[1]));
        for family in FAMILIES {
            assert!(
                family
                    .iter()
                    .any(|member| VOCABULARY.binary_search(member).is_ok()),
                "family without an EYE tag: {family:?}"
            );
            for member in *family {
                assert_eq!(*member, normalize(member), "unnormalised family member");
            }
        }
        for (head, linked) in ASSOCIATIONS {
            assert_eq!(*head, normalize(head), "unnormalised association head");
            for member in *linked {
                assert!(
                    VOCABULARY.binary_search(member).is_ok(),
                    "association target is not an EYE tag: {member}"
                );
            }
        }
    }
}
