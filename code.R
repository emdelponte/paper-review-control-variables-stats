# ==============================================================================
# OpenAlex Sampling & Unpaywall PDF Acquisition Workflow (2011–2025)
# ==============================================================================
# Description:
#   This script queries the OpenAlex API to identify quantitative plant disease 
#   control articles published in 13 key plant pathology journals between 2011 
#   and 2025. It performs random stratified sampling (up to 4 articles per 
#   journal-year stratum), fetches open-access PDF locations via the Unpaywall 
#   API, downloads available PDF documents, and exports the final dataset.
#
# Reproducibility Notes:
#   - Random seed set to 123 for exact reproducibility.
#   - Polite rate limiting (Sys.sleep) is included for both APIs.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. SETUP & DEPENDENCIES
# ------------------------------------------------------------------------------
# Ensure required packages are installed:
# install.packages(c("httr2", "tidyverse", "fs", "janitor"))

library(httr2)
library(tidyverse)
library(fs)
library(janitor)

# Environment variables for API keys and identification:
# Set OPENALEX_API_KEY and UNPAYWALL_EMAIL in your .Renviron file
api_key <- Sys.getenv("OPENALEX_API_KEY", unset = "")
email   <- Sys.getenv("UNPAYWALL_EMAIL", unset = "")

if (!nzchar(email)) {
  message("Note: UNPAYWALL_EMAIL is not set in environment. Set Sys.setenv(UNPAYWALL_EMAIL = 'your_email@domain.com') for Unpaywall API calls.")
}

# ------------------------------------------------------------------------------
# 2. JOURNAL TARGET GRID SETUP
# ------------------------------------------------------------------------------
# Define target plant pathology journals and online ISSN identifiers
journals <- tibble::tribble(
  ~journal_target,                             ~issn_print,  ~issn_online,
  "Phytopathology Research",                   "NA",         "2524-4167",
  "Phytopathology",                            "0031-949X",  "1943-7684",
  "Plant Pathology",                           "0032-0862",  "1365-3059",
  "Journal of Plant Diseases and Protection",  "1861-3829",  "1861-3837",
  "The Plant Pathology Journal",               "1598-2254",  "2093-9280",
  "Journal of Plant Pathology",                "1125-4653",  "2239-7264",
  "European Journal of Plant Pathology",       "0929-1873",  "1573-8469",
  "Tropical Plant Pathology",                  "1982-5676",  "1983-2052",
  "Canadian Journal of Plant Pathology",       "0706-0661",  "1715-2992",
  "Phytopathologia Mediterranea",              "0031-9465",  "1593-2095",
  "Journal of General Plant Pathology",        "1345-2630",  "1610-739X",
  "Journal of Phytopathology",                 "0931-1785",  "1439-0434",
  "Australasian Plant Pathology",              "0815-3191",  "1448-6032"
)

# Extract active online ISSNs for querying
journal_issns <- journals |>
  pivot_longer(
    cols = c(issn_print, issn_online),
    names_to = "issn_type",
    values_to = "issn"
  ) |>
  filter(!is.na(issn), issn != "NA") |> 
  filter(issn_type == "issn_online")

# Search terms to query
terms <- c("control")

# Build target search grid
search_grid <- crossing(
  term = terms,
  journal_issns
)

# ------------------------------------------------------------------------------
# 3. OPENALEX QUERY FUNCTION
# ------------------------------------------------------------------------------
#' Query OpenAlex API for works matching term and ISSN
#' 
#' @param term Search keyword (e.g. "control")
#' @param journal_target Target journal display name
#' @param issn Journal ISSN used for filtering
#' @param issn_type Type of ISSN ("issn_online" or "issn_print")
#' @param from Start date (YYYY-MM-DD)
#' @param to End date (YYYY-MM-DD)
#' @param per_page Number of results per API request page
#' @return A tibble containing extracted work metadata
search_openalex <- function(term,
                            journal_target,
                            issn,
                            issn_type,
                            from = "2011-01-01",
                            to = "2025-12-31",
                            per_page = 25) {
  
  base_url <- "https://api.openalex.org/works"
  
  filter_string <- paste0(
    "primary_location.source.issn:", issn,
    ",type:article",
    ",from_publication_date:", from,
    ",to_publication_date:", to
  )
  
  get_page_json <- function(page) {
    Sys.sleep(0.5) # Polite delay
    
    req <- request(base_url) |>
      req_url_query(
        filter = filter_string,
        search = term,
        per_page = per_page,
        page = page
      )
    
    if (nzchar(api_key)) {
      req <- req |> req_url_query(api_key = api_key)
    }
    
    req |>
      req_retry(
        max_tries = 5,
        backoff = ~ 2^.x
      ) |>
      req_perform() |>
      resp_body_json(simplifyVector = FALSE)
  }
  
  first <- get_page_json(1)
  
  total <- first$meta$count
  n_pages <- ceiling(total / per_page)
  
  message(
    journal_target, " | ", issn, " | ", term,
    ": ", total, " records; ", n_pages, " pages"
  )
  
  if (total == 0) {
    return(tibble())
  }
  
  pages <- if (n_pages == 1) {
    list(first)
  } else {
    c(list(first), map(2:n_pages, get_page_json))
  }
  
  map_dfr(pages, function(pg) {
    map_dfr(pg$results, function(x) {
      tibble(
        journal_target = journal_target,
        issn_used = issn,
        issn_type = issn_type,
        search_term = term,
        title = x$display_name %||% NA_character_,
        year = x$publication_year %||% NA_integer_,
        doi = x$doi %||% NA_character_,
        cited_by_count = x$cited_by_count %||% NA_integer_,
        journal_openalex = x$primary_location$source$display_name %||% NA_character_,
        openalex_id = x$id %||% NA_character_
      )
    })
  })
}

# ------------------------------------------------------------------------------
# 4. EXECUTE SEARCH & STRATIFIED SAMPLING
# ------------------------------------------------------------------------------
message("Starting OpenAlex search queries...")

res <- pmap_dfr(
  search_grid,
  \(term, journal_target, issn_type, issn) {
    search_openalex(
      term = term,
      journal_target = journal_target,
      issn = issn,
      issn_type = issn_type,
      from = "2011-01-01",
      to = "2025-12-31"
    )
  }
)

# Clean results: verify title contains search terms and remove duplicates
res_clean <- res |>
  filter(str_detect(
    str_to_lower(title),
    str_c(terms, collapse = "|")
  )) |>
  distinct(openalex_id, .keep_all = TRUE) |>
  arrange(journal_target, desc(year), title)

# Set seed for reproducible random sampling
set.seed(123)

# Stratified random sampling: up to 4 articles per journal and year
sampled_articles <- res_clean |>
  group_by(journal_target, year) |>
  group_modify(~ {
    .x |>
      slice_sample(n = min(4, nrow(.x)))
  }) |>
  ungroup() |>
  arrange(journal_target, desc(year), title)

message("Sampled ", nrow(sampled_articles), " articles across target journals and years.")

# ------------------------------------------------------------------------------
# 5. UNPAYWALL PDF RESOLVER FUNCTION
# ------------------------------------------------------------------------------
#' Query Unpaywall API for Open Access PDF URL
#' 
#' @param doi Article DOI
#' @param email User email for Unpaywall polite pool API identification
#' @return String containing PDF URL or NA_character_ if unavailable
get_unpaywall_pdf <- function(doi, email) {
  
  if (is.na(doi) || doi == "") {
    return(NA_character_)
  }
  
  doi_clean <- doi |>
    str_remove("^https://doi.org/") |>
    str_remove("^http://dx.doi.org/") |>
    str_remove("^http://doi.org/") |>
    str_trim()
  
  req <- request("https://api.unpaywall.org/v2") |>
    req_url_path_append(URLencode(doi_clean, reserved = TRUE))
  
  if (nzchar(email)) {
    req <- req |> req_url_query(email = email)
  }
  
  dat <- req |>
    req_timeout(20) |>
    req_retry(max_tries = 3) |>
    req_perform() |>
    resp_body_json(simplifyVector = FALSE)
  
  # 1. Best OA location URL
  pdf1 <- dat$best_oa_location$url_for_pdf
  if (!is.null(pdf1) && length(pdf1) == 1 && !is.na(pdf1) && pdf1 != "") {
    return(pdf1)
  }
  
  # 2. Alternative key name fallback
  pdf2 <- dat$best_oa_location$pdf_url
  if (!is.null(pdf2) && length(pdf2) == 1 && !is.na(pdf2) && pdf2 != "") {
    return(pdf2)
  }
  
  # 3. Check secondary OA locations
  oa_locs <- dat$oa_locations
  if (!is.null(oa_locs) && length(oa_locs) > 0) {
    pdfs <- map_chr(oa_locs, \(x) {
      y <- x$url_for_pdf
      if (is.null(y) || length(y) == 0) NA_character_ else y
    })
    pdfs <- pdfs[!is.na(pdfs) & pdfs != ""]
    if (length(pdfs) > 0) {
      return(pdfs[1])
    }
  }
  
  NA_character_
}

# ------------------------------------------------------------------------------
# 6. PDF ACQUISITION & CSV EXPORT
# ------------------------------------------------------------------------------
# Query Unpaywall for each sampled article
sampled_with_pdf <- sampled_articles |>
  mutate(
    pdf_url = map2_chr(doi, seq_along(doi), \(x, i) {
      message("Checking DOI ", i, " of ", nrow(sampled_articles))
      Sys.sleep(0.2)
      tryCatch(
        get_unpaywall_pdf(x, email = email),
        error = \(e) NA_character_
      )
    })
  )

# Ensure local PDF directory exists
dir_create("pdfs")

# Download helper function
download_pdf <- function(pdf_url, filename) {
  if (is.na(pdf_url) || pdf_url == "") {
    return(FALSE)
  }
  
  tryCatch({
    request(pdf_url) |>
      req_retry(max_tries = 3) |>
      req_perform(path = filename)
    TRUE
  }, error = function(e) {
    FALSE
  })
}

# Generate local PDF file paths and execute downloads
sampled_with_pdf <- sampled_with_pdf |>
  mutate(
    file_name = paste0(
      year, "_",
      str_replace_all(journal_target, "[^A-Za-z0-9]+", "_"), "_",
      str_sub(str_replace_all(title, "[^A-Za-z0-9]+", "_"), 1, 70),
      ".pdf"
    ),
    file_path = file.path("pdfs", file_name)
  ) |>
  mutate(
    downloaded = map2_lgl(pdf_url, file_path, download_pdf)
  )

# Print download summary
message("Download Summary:")
print(table(downloaded = sampled_with_pdf$downloaded, useNA = "always"))

# Save dataset output
write_csv(sampled_with_pdf, "sampled_articles_with_pdf_links.csv")
message("Saved results to sampled_articles_with_pdf_links.csv")
