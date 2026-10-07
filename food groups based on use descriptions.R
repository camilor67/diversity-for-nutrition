# load packages
library(readxl)

# load data
setwd(dir = "C:/Users/tobia/Dropbox/VAVILOV_2.0/Results/species_lists/species_curated/TO_CHECK")
dat <- read_excel("Species_20260508_edible_part_curated.xlsx", sheet = "Species_list")

# load keywords - food groups table
setwd(dir = "C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/Tables Chrystian")
keywords <- read.csv("keywords_food_group.csv")

# make an empty list to store the results
dat_added <- list()

# loop through the rows
for (r in (1:nrow(dat))) {
  
  # get use
  use <- dat$use[r]
  
  # only continue of use is not NA
  if(!is.na(use)) {
    
    # check if any of the keywords are found in the use description
    for (k in 1:nrow(keywords)) {
      
      keyword <- keywords$keyword[k]
      g <- grepl(pattern = paste0("\\b", keyword, "\\b"), use)
      
      # if yes, add the row as a new row to dat_new
      # but only if that species x food group combination is not in the database yet
      if(g == TRUE) {
        
        # check food groups for the species
        j <- which(dat$species == dat$species[r])
        food_groups <- dat$food_group[j]
        
        if(!(keywords$food_group[k] %in% food_groups)) {
          
          dat_new <- dat[r,]
          dat_new$food_group<- keywords$food_group[k]
          
          # fill in other columns where necessary
          dat_new$part <- NA
          dat_new$edible_portion <- NA
          dat_new$plant_part <- "?"
          dat_new$plant_part_tentative <- ""
          dat_new$plant_part_database_ref <- "FPI use description"
          dat_new$plant_part_ref <- "FPI use description"
          dat_new$plant_part_assumption <- ""
          dat_new$food_group_orig <- ""
          dat_new$food_group_tentative <- 0
          dat_new$food_group_assumption <- paste0("Based on FPI use description using keywords: ",
                                                  keywords$keyword[k],  " -> ",
                                                  keywords$food_group[k])
          print(paste0("row added: ", 
                       dat_new$food_group, " - ", keywords$keyword[k], " - ", dat_new$use))
          
          # add to list
          dat_added[[length(dat_added) + 1]] <- dat_new
          
        }
      }
    }
  }
}

# rbind the list
dat_added <- do.call("rbind", dat_added)

# remove duplicates
i <- which(duplicated(paste0(dat_added$species, dat_added$food_group)))
dat_added <- dat_added[-i,]

# add an extra row
dat_added$row_added_with_R  <- 1

# save
setwd(dir = "C:/Users/tobia/Dropbox/VAVILOV_2.0/Results/species_lists/species_curated/TO_CHECK")
write.csv(dat_added, "extra_data_use_descriptions.csv")






