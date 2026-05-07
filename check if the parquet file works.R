# load packages
library(arrow)
library(data.table)

# open and read into data.table
dt <- as.data.table(read_parquet("C:/Users/tobia/Dropbox/Diversity for Nutrition/diversity-for-nutrition-data/D4N_data/species_presence.parquet"))

# quick check
cat(sprintf("Rows: %d | Species: %d\n", nrow(dt), uniqueN(dt$species)))
str(dt)

# get first species
sp <- dt$species[1]
dt_sp <- dt[species == sp]

# snap resolution
res_deg <- 0.041667

# snap lon/lat to nearest grid cell centre
dt_sp[, lon_snap := round(lon / res_deg) * res_deg]
dt_sp[, lat_snap := round(lat / res_deg) * res_deg]

# build raster from snapped extent
ext_sp <- ext(min(dt_sp$lon_snap) - res_deg/2, max(dt_sp$lon_snap) + res_deg/2,
              min(dt_sp$lat_snap) - res_deg/2, max(dt_sp$lat_snap) + res_deg/2)
r <- rast(ext_sp, resolution = res_deg, crs = "EPSG:4326")

# rasterize using snapped coordinates
cells <- cellFromXY(r, as.matrix(dt_sp[, .(lon_snap, lat_snap)]))

r_now  <- r; r_now[cells]  <- dt_sp$present_now
r_ssp2 <- r; r_ssp2[cells] <- dt_sp$present_ssp2
r_ssp3 <- r; r_ssp3[cells] <- dt_sp$present_ssp3

stk <- c(r_now, r_ssp2, r_ssp3)
names(stk) <- c("present_now", "present_ssp2", "present_ssp3")
plot(stk, main = sp)
