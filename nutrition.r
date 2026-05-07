# Orchestrator script for Diversity for Nutrition tool
# R_HOME is already defined by config.r (sourced from functions.r before this file).

source(file.path(R_HOME, "src", "libs.r"))
source(file.path(R_HOME, "src", "io", "helpers.r"))
source(file.path(R_HOME, "src", "io", "utils.r"))
source(file.path(R_HOME, "src", "input", "parse_inputs.r"))
source(file.path(R_HOME, "src", "input", "get_biome.r"))
source(file.path(R_HOME, "src", "data", "load_data.r"))
source(file.path(R_HOME, "src", "data", "load_maps.r"))
source(file.path(R_HOME, "src", "analysis", "species_analysis.r"))
source(file.path(R_HOME, "src", "output", "report_data.r"))

# main function to call the other functions
process_nutrition <- function(lon = NULL,
                              lat = NULL,
                              edible_parts_ID = NULL,
                              food_groups_ID = NULL,
                              growth_forms_ID = NULL,
                              species_type_ID = NULL,
                              soil_con_ID = NULL,
                              within_range = NULL,
                              incl_tentative = NULL,
                              SSP = NULL,
                              language_output = NULL) {
    
    ##############################################################################
    # 1. Parse inputs
    ##############################################################################
    inputs <- parse_nutrition_inputs(
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
    # print(inputs)
    
    ##############################################################################
    # 1. Load data
    ##############################################################################
    data <- load_data(
      DATA_FOLDER = DATA_FOLDER,
      language_output = inputs$language_output
    )
    # print(data)
    
    ##############################################################################
    # 2. Get biome
    ##############################################################################
    # Use inputs$lon / inputs$lat (already coerced to numeric by
    # parse_nutrition_inputs). The raw lon/lat arguments arrive as strings
    # whenever the function is invoked from the web app, which makes
    # terra::vect(matrix(c(lon,lat),...)) fail with "coordinates must be numeric".
    biome <- get_biome(
      lon = inputs$lon,
      lat = inputs$lat,
      DATA_FOLDER = DATA_FOLDER
    )
    # print(biome)
    
    ##############################################################################
    # 3. Extract species that can be grown at selected location
    ##############################################################################
    species_extr <- extract_suitable_species_parquet(
       lon = inputs$lon,
       lat = inputs$lat,
       SSP = inputs$SSP,
       within_range = inputs$within_range
    )
    # print(species_extr)
    
    ##############################################################################
    # 4. Get country and region
    ##############################################################################
    country <- coords2country(inputs$lon, inputs$lat)
    region <- region_from_country(country)
    
    ##############################################################################
    # Load maps
    ##############################################################################
    # Resolve country+region once (used by load_maps and the report payload).
    # SA/CA split is only applied in load_maps when SPLIT_MAPS_BY_REGION=TRUE.
    # country <- coords2country(inputs$lon, inputs$lat)
    # region <- region_from_country(country)
    # 
    # maps <- load_maps(
    #   species_set = data$species_set,
    #   DATA_FOLDER = DATA_FOLDER,
    #   BUCKET_NAME = BUCKET_NAME,
    #   within_range = inputs$within_range,
    #   SSP = inputs$SSP,
    #   biome = biome$biome_name,
    #   region = region
    # )
    # # print(maps)

    ##############################################################################
    # Extract species that can grow at selected site
    ##############################################################################
    # species_extr <- extract_suitable_species(
    #   lon = inputs$lon,
    #   lat = inputs$lat,
    #   maps_present = maps$distr_stack,
    #   maps_future = maps$distr_stack_future
    # )
    # print(species_extr)
    
    ##############################################################################
    # 5. Filter species
    ##############################################################################
    species_filt <- filter_species(
      nutr_dat = data$nutr_dat,
      soil_dat = data$soil_dat,
      edible_parts = data$edible_parts,
      food_groups = data$food_groups,
      growth_forms = data$growth_forms,
      species_types = data$species_types,
      suitable_species = species_extr$suitable_species,
      n_models = species_extr$n_models,
      edible_parts_ID = inputs$edible_parts_ID,
      food_groups_ID = inputs$food_groups_ID,
      growth_forms_ID = inputs$growth_forms_ID,
      species_type_ID = inputs$species_type_ID,
      soil_con_ID = inputs$soil_con_ID,
      biome = biome$biome_name,
      incl_tentative = inputs$incl_tentative,
      language_output = inputs$language_output
    )
    ##############################################################################
    # 6. Generate report data (JSON for frontend consumption)
    ##############################################################################
    generate_report_data(
      inputs        = inputs,
      country       = country,
      region        = region,
      biome_name    = biome$biome_name,
      species_filt  = species_filt,
      trans_df      = data$trans_df,
      output_folder = REPORT_FOLDER
    )

}
