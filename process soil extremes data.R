# load packages
library(readxl)

# load data
setwd(dir = "C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/Tables Chrystian")
df <- read_xlsx("soil_outliers_list_continental_20261015.xlsx")

setwd(dir = "C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/Tables")
var_cats <- read.csv("D4N_soil_vars.csv")
var_cats <- var_cats[!is.na(var_cats$var), ]

# flag species with n >= 30 whose median falls outside the continental reference IQR
df$outlier_low  <- df$n_obs_sp >= 30 & df$sp_median < df$Q25_ref
df$outlier_high <- df$n_obs_sp >= 30 & df$sp_median > df$Q75_ref
df$outlier      <- df$outlier_low | df$outlier_high

# match on var + direction, leave empty if no category_EN defined
df$category <- mapply(function(v, lo, hi) {
  if (lo) {
    m <- var_cats$category_EN[var_cats$var == v & var_cats$limit == "L"]
  } else if (hi) {
    m <- var_cats$category_EN[var_cats$var == v & var_cats$limit == "H"]
  } else {
    return("")
  }
  if (length(m) == 0) "" else m
}, df$var, df$outlier_low, df$outlier_high)

# match with extreme soil condition ID
df$category_ID <- NA
m <- match(df$category, var_cats$category_EN)
df$category_ID <- var_cats$ID_extreme[m]

# inspect
summary(df)

# save
df <- df[c("species_searched", "var", "n_obs_sp", "sp_median", "category", "category_ID")]
names(df)[names(df) == "species_searched"] <- "species"
setwd(dir = "C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/Tables")
write.csv(df, "D4N_soil_extremes.csv", row.names = FALSE)




