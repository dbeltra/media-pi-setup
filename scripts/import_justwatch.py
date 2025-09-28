#!/usr/bin/env python

import requests
from dotenv import load_dotenv
import json
import os
from pathlib import Path

# Load .env from project root (parent directory of scripts/)
env_path = Path(__file__).parent.parent / '.env'
load_dotenv(dotenv_path=env_path)

TMDB_API_KEY = os.getenv("TMDB_API_KEY")
RADARR_API_KEY = os.getenv("RADARR_API_KEY")
RADARR_URL = os.getenv("RADARR_URL")
JUSTWATCH_LIST_ID = os.getenv("JUSTWATCH_LIST_ID")
RADARR_ROOT_FOLDER = os.getenv("RADARR_ROOT_FOLDER", "/movies")
RADARR_QUALITY_PROFILE_ID = int(os.getenv("RADARR_QUALITY_PROFILE_ID", "1"))
LOGFILE_PATH = os.getenv("LOGFILE_PATH")
MAX_SIZE_MB = 5  # Rotate if bigger than 5 MB

def rotate_log():
    if os.path.exists(LOGFILE_PATH):
        size = os.path.getsize(LOGFILE_PATH) / (1024 * 1024)
        if size > MAX_SIZE_MB:
            old_log = LOGFILE_PATH + ".old"
            if os.path.exists(old_log):
                os.remove(old_log)
            os.rename(LOGFILE_PATH, old_log)



def get_movies_justwatch():
    GRAPHQL_URL = "https://apis.justwatch.com/graphql"

    HEADERS = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36",
        "Accept": "*/*",
        "Content-Type": "application/json",
        "Origin": "https://www.justwatch.com",
        "Referer": "https://www.justwatch.com/",
        "app-version": "3.10.0-web-web",
        "device-id": "",
        "sg": "",
    }

    PAYLOAD = {
        "operationName": "GetGenericList",
        "variables": {
            "sortBy": "NATURAL",
            "sortRandomSeed": 0,
            "platform": "WEB",
            "listId": JUSTWATCH_LIST_ID,
            "titleListAfterCursor": "",
            "country": "US",
            "language": "en",
            "first": 100,
            "filter": {
            },
            "watchNowFilter": {"packages": [], "monetizationTypes": []},
        },
        "query": "query GetGenericList($listId: ID!, $country: Country!, $language: Language!, $first: Int!, $filter: TitleFilter!, $sortBy: GenericTitleListSorting! = POPULAR, $sortRandomSeed: Int! = 0, $watchNowFilter: WatchNowOfferFilter!, $titleListAfterCursor: String, $platform: Platform! = WEB, $profile: PosterProfile, $backdropProfile: BackdropProfile, $format: ImageFormat) {\n  listDetails: node(id: $listId) {\n    ...ListDetails\n    __typename\n  }\n  genericTitleList(\n    id: $listId\n    country: $country\n    after: $titleListAfterCursor\n    first: $first\n    filter: $filter\n    sortBy: $sortBy\n    sortRandomSeed: $sortRandomSeed\n  ) {\n    pageInfo {\n      endCursor\n      hasNextPage\n      hasPreviousPage\n      __typename\n    }\n    totalCount\n    edges {\n      node {\n        ...GenericListTitle\n        __typename\n      }\n      __typename\n    }\n    __typename\n  }\n}\n\nfragment ListDetails on GenericTitleList {\n  id\n  name\n  type\n  ownedByUser\n  followedlistEntry {\n    createdAt\n    name\n    __typename\n  }\n  __typename\n}\n\nfragment GenericListTitle on MovieOrShow {\n  id\n  objectId\n  objectType\n  content(country: $country, language: $language) {\n    title\n    fullPath\n    scoring {\n      imdbScore\n      __typename\n    }\n    posterUrl(profile: $profile, format: $format)\n    ... on ShowContent {\n      backdrops(profile: $backdropProfile, format: $format) {\n        backdropUrl\n        __typename\n      }\n      __typename\n    }\n    isReleased\n    __typename\n  }\n  likelistEntry {\n    createdAt\n    __typename\n  }\n  dislikelistEntry {\n    createdAt\n    __typename\n  }\n  watchlistEntryV2 {\n    createdAt\n    __typename\n  }\n  customlistEntries {\n    createdAt\n    __typename\n  }\n  watchNowOffer(country: $country, platform: $platform, filter: $watchNowFilter) {\n    id\n    standardWebURL\n    preAffiliatedStandardWebURL\n    package {\n      id\n      packageId\n      clearName\n      __typename\n    }\n    retailPrice(language: $language)\n    retailPriceValue\n    lastChangeRetailPriceValue\n    currency\n    presentationType\n    monetizationType\n    availableTo\n    __typename\n  }\n  ... on Movie {\n    seenlistEntry {\n      createdAt\n      __typename\n    }\n    __typename\n  }\n  ... on Show {\n    seenState(country: $country) {\n      seenEpisodeCount\n      progress\n      __typename\n    }\n    __typename\n  }\n  __typename\n}\n",
    }

    session = requests.Session()
    session.get("https://www.justwatch.com", headers=HEADERS)
    resp = session.post(GRAPHQL_URL, headers=HEADERS, json=PAYLOAD)
    data = json.loads(resp.text)

    movies = []
    for edge in data["data"]["genericTitleList"]["edges"]:
        node = edge["node"]
        content = node["content"]
        movies.append({
            "title": content["title"],
            "imdb_score": content["scoring"].get("imdbScore"),
            "path": content["fullPath"],
            "poster": content["posterUrl"],
            "object_id": node["objectId"]
        })

    return movies

def search_tmdb(title):
    url = f"https://api.themoviedb.org/3/search/movie"
    params = {"api_key": TMDB_API_KEY, "query": title}
    r = requests.get(url, params=params)
    r.raise_for_status()
    data = r.json()
    if data["results"]:
        return data["results"][0]  # Take first hit
    return None

def add_movie_to_radarr(tmdb_id, title):
    url = f"{RADARR_URL}/api/v3/movie"
    headers = {"X-Api-Key": RADARR_API_KEY}
    payload = {
        "tmdbId": tmdb_id,
        "qualityProfileId": RADARR_QUALITY_PROFILE_ID,  
        "title": title,
        "rootFolderPath": RADARR_ROOT_FOLDER,
        "monitored": True,
        "addOptions": {
            "searchForMovie": True
        }
    }
    r = requests.post(url, headers=headers, json=payload)
    r.raise_for_status()
    print(f"Added: {title} (TMDb ID {tmdb_id})")


def get_existing_tmdb_ids():
    url = f"{RADARR_URL}/api/v3/movie"
    headers = {"X-Api-Key": RADARR_API_KEY}
    r = requests.get(url, headers=headers)
    r.raise_for_status()
    data = r.json()
    tmdb_ids = [m["tmdbId"] for m in data]
    return tmdb_ids

if __name__ == "__main__":
    rotate_log()

    try:
        movies = get_movies_justwatch()
        existing_tmdb_ids = get_existing_tmdb_ids()
        added_count = 0

        for movie in movies:
            try:
                tmdb_data = search_tmdb(movie["title"])
                if not tmdb_data:
                    print(f"No TMDb match for: {movie['title']}")
                    continue

                tmdb_id = tmdb_data["id"]
                title = tmdb_data["original_title"]

                if tmdb_id in existing_tmdb_ids:
                    print(f"Already in Radarr: {movie['title']} (TMDb ID {tmdb_id})")
                    continue
                
                add_movie_to_radarr(tmdb_id=tmdb_id, title=title)
                print(f"Added {movie['title']} to Radarr")
                added_count += 1
                
            except Exception as e:
                print(f"Error processing {movie['title']}: {e}")
                continue
        
        print(f"Script completed. Added {added_count} new movies to Radarr.")
        
    except Exception as e:
        print(f"Script failed: {e}")
        exit(1)
