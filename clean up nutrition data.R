# load data
setwd(dir = "C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/Tables")
df <- read.csv("D4N_species_nutrition_data.csv", colClasses = "character", check.names = FALSE, na.strings = character(0))

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

# trim leading/trailing spaces in all columns
df[] <- lapply(df, trimws)

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

# plant parts: match labels in D4N_plant_parts.csv
fix_plant_part <- c(
  "roots/tubers" = "roots",
  "Roots"        = "roots",
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
  "Flower buds"  = "inflorescences"
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
                  "Unclear plant part/food group reported in edible portion")
for (col in names(lookups)) {
  left <- df[[col]][!df[[col]] %in% c(lookups[[col]], placeholders)]
  cat("\n", col, ": ", length(left), " rows still not matching\n", sep = "")
  if (length(left)) print(table(substr(left, 1, 60)))
}

# save
write.csv(df, "D4N_species_nutrition_data.csv", row.names = FALSE, na = "", fileEncoding = "UTF-8")
