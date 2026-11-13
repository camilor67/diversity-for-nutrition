# load data
setwd(dir = "C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/Tables")
df <- read.csv("D4N_species_nutrition_data_latest.csv", colClasses = "character", check.names = FALSE, na.strings = character(0))

# fix encoding: cells that are not valid UTF-8 were saved as Windows-1252
# (only the invalid bytes are converted, since some cells mix UTF-8 and Windows-1252)
fix_bytes <- function(x) {
  x <- iconv(x, from = "UTF-8", to = "UTF-8", sub = "byte")  # invalid bytes become "<e9>"
  hex <- unique(unlist(regmatches(x, gregexpr("<[0-9a-f]{2}>", x))))
  for (h in hex) {
    ch <- iconv(rawToChar(as.raw(strtoi(substr(h, 2, 3), 16L))), from = "windows-1252", to = "UTF-8")
    if (is.na(ch)) ch <- ""  # byte undefined in Windows-1252
    x <- gsub(h, ch, x, fixed = TRUE)
  }
  x
}
for (k in seq_along(df)) {
  bad <- !validUTF8(df[[k]])
  df[[k]][bad] <- fix_bytes(df[[k]][bad])
}

# fix text that is valid UTF-8 but was decoded as Windows-1252 once and saved
# again ("Plantas Ãštiles", "CatÃ³lica": 4 827 rows in the 2026-11 delivery,
# 218 in 2026-10). Each run of characters that spells one UTF-8 sequence in
# Windows-1252 (a lead byte C2-F4, then its continuation bytes 80-BF) is turned
# back into those bytes and kept only if they decode as valid UTF-8, so real
# text like "SÃO PAULO" (C3 followed by "O", not a continuation) is untouched.
# Bytes 81, 8D, 8F, 90 and 9D are undefined in Windows-1252 and arrive as the
# Latin-1 control characters, which is why both encodings are tried per char.
cont <- paste0("[\\x{0080}-\\x{00BF}\\x{20AC}\\x{201A}\\x{0192}\\x{201E}\\x{2026}",
               "\\x{2020}\\x{2021}\\x{02C6}\\x{2030}\\x{0160}\\x{2039}\\x{0152}",
               "\\x{017D}\\x{2018}\\x{2019}\\x{201C}\\x{201D}\\x{2022}\\x{2013}",
               "\\x{2014}\\x{02DC}\\x{2122}\\x{0161}\\x{203A}\\x{0153}\\x{017E}\\x{0178}]")
mojibake <- paste0("(*UTF)(?:[\\x{00C2}-\\x{00DF}]", cont, "|[\\x{00E0}-\\x{00EF}]", cont, "{2}",
                   "|[\\x{00F0}-\\x{00F4}]", cont, "{3})")
unmojibake <- function(run) {
  chars <- strsplit(run, "")[[1]]
  bytes <- lapply(chars, function(ch) {
    b <- iconv(ch, "UTF-8", "windows-1252", toRaw = TRUE)[[1]]
    if (is.null(b)) b <- iconv(ch, "UTF-8", "latin1", toRaw = TRUE)[[1]]
    b
  })
  if (any(vapply(bytes, is.null, logical(1)))) return(run)
  out <- rawToChar(do.call(c, bytes))
  Encoding(out) <- "UTF-8"
  if (validUTF8(out)) out else run
}
fix_mojibake <- function(x) {
  Encoding(x) <- "UTF-8"  # every cell is valid UTF-8 after fix_bytes()
  for (pass in 1:3) {  # text saved wrongly twice needs two passes
    hit <- grepl(mojibake, x, perl = TRUE)
    if (!any(hit)) break
    before <- x[hit]
    m <- gregexpr(mojibake, before, perl = TRUE)
    runs <- regmatches(before, m)
    after <- before
    regmatches(after, m) <- lapply(runs, function(r) vapply(r, unmojibake, character(1), USE.NAMES = FALSE))
    if (identical(after, before)) break
    x[hit] <- after
  }
  x
}
df[] <- lapply(df, fix_mojibake)

# trim leading/trailing spaces in all columns
df[] <- lapply(df, trimws)

# references: restore the "//" missing after "http:" / "https:"
df$plant_part_ref <- gsub("(https?:)(?!//)", "\\1//", df$plant_part_ref, perl = TRUE)

# food groups: match labels in D4N_food_groups.csv
fix_food_group <- c(
  "food additive"                 = "food additives",
  "oil/fats"                      = "oils and fats",
  "gums/mucilages"                = "gums and mucilages",
  "sugar, syrups and sweet foods" = "sugar and syrups",
  "leaves"                        = "vegetables",
  "vegetable"                     = "vegetables",
  "No food group information"     = "No food group available"
)
m <- df$food_group %in% names(fix_food_group)
df$food_group[m] <- fix_food_group[df$food_group[m]]

# food groups still under review by the curators (2026-11: 32 rows, 23 of them
# Inga, where the edible part is the aril/pod pulp): keep the likely group,
# flagged as tentative, so a report never prints the curators' note and
# "exclude tentative" drops them
m <- df$food_group == "A checkear (dessert fruits?)"
df$food_group[m] <- "dessert fruits"
df$food_group_tentative[m] <- "1"

# plant parts: match labels in D4N_plant_parts.csv
fix_plant_part <- c(
  # 2026-11: the option is labelled "roots/tubers" (Evert), in D4N_plant_parts.csv too
  "roots"        = "roots/tubers",
  "Roots"        = "roots/tubers",
  "nuts/seeds"   = "seeds",
  "seed"         = "seeds",
  "Seeds"        = "seeds",
  "fruit"        = "fruits",
  "Fruit"        = "fruits",
  "Stem"         = "stems",
  "Stems"        = "stems",
  "Leaves"       = "leaves",
  "Latex"        = "exudates",
  "mucilages"    = "exudates",
  "Flower buds"     = "flowers",
  "infructescences" = "fruits",
  "inflorescences"  = "flowers",
  "Inflorescences"  = "flowers"
)
m <- df$plant_part %in% names(fix_plant_part)
df$plant_part[m] <- fix_plant_part[df$plant_part[m]]

# growth forms: "lia" is a truncated "liana"
df$growth_form <- gsub("\\blia\\b", "liana", df$growth_form)

# wild_or_cultivated: empty rows with cultivated = 1 become "cultivated" (same rule as existing rows)
m <- df$wild_or_cultivated == "" & df$cultivated == "1"
df$wild_or_cultivated[m] <- "cultivated"

# check: values still not matching the lookup tables (need a decision)
lookups <- list(
  plant_part         = read.csv("D4N_plant_parts.csv")$plant_part,
  food_group         = read.csv("D4N_food_groups.csv")$food_group,
  wild_or_cultivated = read.csv("D4N_species_types.csv")$species_type
)
placeholders <- c("Not available plant part", "No food group available",
                  "Unclear plant part/food group reported in edible portion",
                  "Plant part unavailable/unclear", "Food group unavailable/unclear")
for (col in names(lookups)) {
  left <- df[[col]][!df[[col]] %in% c(lookups[[col]], placeholders)]
  cat("\n", col, ": ", length(left), " rows still not matching\n", sep = "")
  if (length(left)) print(table(substr(left, 1, 60)))
}

# save
write.csv(df, "D4N_species_nutrition_data.csv", row.names = FALSE, na = "", fileEncoding = "UTF-8")
