# =============================================================================
# Loading data from S3 and filtering objectives/conditions/species
# =============================================================================

# load data
load_data <- function(DATA_FOLDER,
                      language_output) {
  
  log_step("n01 [load_data]", "Loading nutrition data...")
  
  # load nutrition data
  nutr_dat <- safe_read_csv(file.path(DATA_FOLDER, "Tables", "D4N_species_nutrition_data_20260506.csv"))
  
  # get the species for which models were made
  j <- which(nutr_dat$incl_SDM == 1)
  species_set <- nutr_dat$species[j]
  species_set <- species_set[-which(duplicated(species_set))]
  
  # load edible parts table
  edible_parts <- safe_read_csv(file.path(DATA_FOLDER, "Tables", "D4N_plant_parts.csv"))
  
  # load food groups table
  food_groups <- safe_read_csv(file.path(DATA_FOLDER, "Tables", "D4N_food_groups.csv"))
  
  # load growth forms table
  growth_forms <- safe_read_csv(file.path(DATA_FOLDER, "Tables", "D4N_growth_forms.csv"))
  
  # load species types table
  species_types <- safe_read_csv(file.path(DATA_FOLDER, "Tables", "D4N_species_types.csv"))

  # load soil extremes data
  soil_dat <- safe_read_csv(file.path(DATA_FOLDER, "Tables", "D4N_soil_extremes.csv"))
  
  # load translation table
  trans_df <- safe_read_csv(file.path(DATA_FOLDER, "Tables", "D4N_translation_backend.csv"))
  j <- which(names(trans_df) == language_output)
  trans_df <- trans_df[,c(1,j)]
  trans_df <- data.frame(t(trans_df))
  names(trans_df) <- trans_df[1,]
  trans_df <- trans_df[-1,]
  
  # return of the function
  list(
    nutr_dat = nutr_dat,
    species_set = species_set,
    edible_parts = edible_parts,
    food_groups = food_groups,
    growth_forms = growth_forms,
    species_types = species_types,
    soil_dat = soil_dat,
    trans_df = trans_df
  )
}
