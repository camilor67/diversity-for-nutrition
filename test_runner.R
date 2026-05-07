# source functions.R
setwd(dir = "C:/Users/tobia/Documents/diversity-for-nutrition")
source("functions.R")

# test values
lon = -49.91
lat = -26.34
edible_parts_ID = "7,8"
food_groups_ID = "3,15"
growth_forms_ID = "1"
species_type_ID = "1"
soil_con_ID = "2"
within_range = "yes"
incl_tentative = "yes"
SSP = "SSP2"
language_output = "EN"

# call mainNutrition functions
mainNutrition(
  lon = lon,
  lat = lat,
  edible_parts_ID = edible_parts_ID,
  food_groups_ID = food_groups_ID,
  growth_forms_ID = growth_forms_ID,
  species_type_ID = species_type_ID,
  soil_con_ID = soil_con_ID,
  within_range = within_range,
  incl_tentative = incl_tentative,
  SSP = SSP,
  language_output = language_output
)
  