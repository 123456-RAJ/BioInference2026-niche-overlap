# Select the Excel file for analysis
file_path <- file.choose()

# Packages need for the analysis
pkgs <- c("readxl","dplyr","tidyr","stringr","janitor",
          "ggplot2","ade4","ecospat","readr")

to_install <- pkgs[!pkgs %in% rownames(installed.packages())]
if(length(to_install) > 0) install.packages(to_install)

invisible(lapply(pkgs, library, character.only = TRUE))

print(excel_sheets(file_path))

# Output folders
dir.create("outputs/tables", recursive = TRUE, showWarnings = FALSE)
dir.create("outputs/figures", recursive = TRUE, showWarnings = FALSE)

# Line to read fauna sheets 
read_fauna_sheet <- function(path, sheet){
  
  raw <- read_excel(path, sheet = sheet, col_names = FALSE)
  
  # Remove the empty columns
  keep_cols <- sapply(raw, function(col){
    x <- as.character(col)
    any(!is.na(x) & str_squish(x) != "")
  })
  raw <- raw[, keep_cols, drop = FALSE]
  
  # Locate header row
  header_row <- which(apply(raw, 1, function(x)
    any(as.character(x) == "Complete Code")))[1]
  if (is.na(header_row)) stop("Could not find 'Complete Code' in sheet: ", sheet)
  
  # Read header rows
  h1 <- raw[header_row - 2, ] %>% unlist(use.names = FALSE) %>% as.character()
  h2 <- raw[header_row - 1, ] %>% unlist(use.names = FALSE) %>% as.character()
  h3 <- raw[header_row,     ] %>% unlist(use.names = FALSE) %>% as.character()
  
  # Now combine header names
  nm <- ifelse(!is.na(h3) & str_squish(h3) != "", h3,
               ifelse(!is.na(h1) & str_squish(h1) != "", h1, h2))
  
  nm <- str_squish(as.character(nm))
  nm[is.na(nm) | nm == ""] <- paste0("x", which(is.na(nm) | nm == ""))
  nm <- str_replace_all(nm, "\\s+", "_")
  nm <- make.unique(nm, sep = "_")
  
  dat <- raw[(header_row + 1):nrow(raw), , drop = FALSE]
  colnames(dat) <- nm
  
  dat <- dat %>%
    mutate(across(where(is.character), ~ str_squish(.x))) %>%
    clean_names()
  
  # Standardize site ID column
  if(!("complete_code" %in% names(dat))){
    cc <- names(dat)[str_detect(names(dat), "^complete_code")]
    if(length(cc) == 0) stop("No 'complete_code' column after cleaning in sheet: ", sheet)
    dat <- dat %>% rename(complete_code = all_of(cc[1]))
  }
  
  dat %>%
    mutate(complete_code = as.character(complete_code)) %>%
    rename(site_id = complete_code)
}

# Read environmental variables from Excel file
env <- read_excel(file_path, sheet = "ES indicators Data (0-20 cm)") %>%
  clean_names() %>%
  mutate(complete_code = as.character(complete_code)) %>%
  rename(site_id = complete_code)

# Read fauna groups which we want in the analysis
meso  <- read_fauna_sheet(file_path, "Mesofauna")
macro <- read_fauna_sheet(file_path, "Macrofauna")
earth <- read_fauna_sheet(file_path, "Earthworms")

# Keep common sampling sites
common_sites <- Reduce(intersect, list(env$site_id, meso$site_id, macro$site_id, earth$site_id))
cat("Common sites across Env + Mesofauna + Macrofauna + Earthworms:", length(common_sites), "\n")

env2   <- env   %>% filter(site_id %in% common_sites)
meso2  <- meso  %>% filter(site_id %in% common_sites)
macro2 <- macro %>% filter(site_id %in% common_sites)
earth2 <- earth %>% filter(site_id %in% common_sites)

# Build presence - absence data
meta_cols <- c("region","land_use","land_use_intensity","site_id",
               "short_code","description_of_the_intensity")

# Identify taxa columns
taxa_cols_by_exclusion <- function(df){
  setdiff(names(df), meta_cols)
}

# Convert taxa values to numeric values
coerce_taxa_numeric <- function(df, taxa_cols){
  df %>% mutate(across(all_of(taxa_cols), ~ readr::parse_number(as.character(.x))))
}

# Mark those sites where each fauna group is present
presence_mask <- function(df, group_name){
  taxa_cols <- taxa_cols_by_exclusion(df)
  
  df_num <- coerce_taxa_numeric(df, taxa_cols)
  
  # Keep usable taxa columns
  good_cols <- taxa_cols[sapply(df_num[taxa_cols], function(x) any(!is.na(x)))]
  if(length(good_cols) == 0){
    stop("After numeric conversion, still no usable taxa columns in: ", group_name,
         "\nThis means taxa values are blank/non-numeric in this sheet.")
  }
  
  pa <- df_num %>%
    transmute(site_id,
              pa = rowSums(across(all_of(good_cols), ~ replace_na(.x, 0) > 0)) > 0)
  
  cat(group_name, "presence sites:", sum(pa$pa), "/", nrow(pa), "\n")
  pa
}

meso_pa  <- presence_mask(meso2,  "Mesofauna")
macro_pa <- presence_mask(macro2, "Macrofauna")
earth_pa <- presence_mask(earth2, "Earthworms")

# PCA environmental space
env_num <- env2 %>% select(site_id, where(is.numeric))

# Remove variables with many missing values
keep <- sapply(env_num, function(x) mean(is.na(x)) <= 0.30)
env_num <- env_num[, keep, drop = FALSE]

X <- env_num %>% select(-site_id)

# Remove variables without variation
nzv <- sapply(X, function(x) sd(x, na.rm = TRUE) > 0)
X <- X[, nzv, drop = FALSE]
if(ncol(X) < 2) stop("Too few usable environmental variables for PCA after filtering.")

# Fill missing values
X_imp <- X %>% mutate(across(everything(), ~ ifelse(is.na(.x), median(.x, na.rm=TRUE), .x)))

# PCA Analysis
pca <- ade4::dudi.pca(scale(X_imp), scannf = FALSE, nf = 2)

scores <- as.data.frame(pca$li) %>%
  mutate(site_id = env_num$site_id) %>%
  select(site_id, PC1 = Axis1, PC2 = Axis2)

glob <- scores %>% select(PC1, PC2)

# Create Ecospat grids
make_grid <- function(pa_df){
  occ <- scores %>% inner_join(pa_df, by="site_id") %>% filter(pa) %>% select(PC1, PC2)
  if(nrow(occ) < 5) warning("Very few occurrences for a group: ", nrow(occ))
  ecospat.grid.clim.dyn(glob = glob, glob1 = glob, sp = occ, R = 200)
}

grid_meso  <- make_grid(meso_pa)
grid_macro <- make_grid(macro_pa)
grid_earth <- make_grid(earth_pa)

# Calculate niche overlap
pair_stats <- function(g1, g2, n1, n2){
  D <- ecospat.niche.overlap(g1, g2, cor = TRUE)$D
  cat("Schoener's D (", n1, " vs ", n2, ") = ", round(D, 3), "\n", sep="")
  dyn <- ecospat.niche.dyn.index(g1, g2, intersection = 0)
  list(D = D, dyn = dyn)
}

res_meso_macro  <- pair_stats(grid_meso,  grid_macro, "Mesofauna", "Macrofauna")
res_meso_earth  <- pair_stats(grid_meso,  grid_earth, "Mesofauna", "Earthworms")
res_macro_earth <- pair_stats(grid_macro, grid_earth, "Macrofauna", "Earthworms")

# Summarize and save Schoener's D values
D_table <- data.frame(
  Pair = c("Mesofauna vs Macrofauna", "Mesofauna vs Earthworms", "Macrofauna vs Earthworms"),
  Schoeners_D = c(res_meso_macro$D, res_meso_earth$D, res_macro_earth$D)
)

print(D_table)
write_csv(D_table, "outputs/tables/schoeners_D.csv")

# Combined figure
plot_combined_niches <- function(){
  
  par(mfrow = c(2,3))
  
  # Individual niche plots
  ecospat.plot.niche(grid_meso,  title="Mesofauna niche",  name.axis1="PC1", name.axis2="PC2", cor=TRUE)
  ecospat.plot.niche(grid_macro, title="Macrofauna niche", name.axis1="PC1", name.axis2="PC2", cor=TRUE)
  ecospat.plot.niche(grid_earth, title="Earthworms niche", name.axis1="PC1", name.axis2="PC2", cor=TRUE)
  
  # Overlap plots
  ecospat.plot.niche.dyn(grid_meso, grid_macro,
                         intersection = 0,
                         title = paste0("Meso vs Macro (D=", round(res_meso_macro$D,3), ")"),
                         name.axis1="PC1", name.axis2="PC2")
  
  ecospat.plot.niche.dyn(grid_meso, grid_earth,
                         intersection = 0,
                         title = paste0("Meso vs Earth (D=", round(res_meso_earth$D,3), ")"),
                         name.axis1="PC1", name.axis2="PC2")
  
  ecospat.plot.niche.dyn(grid_macro, grid_earth,
                         intersection = 0,
                         title = paste0("Macro vs Earth (D=", round(res_macro_earth$D,3), ")"),
                         name.axis1="PC1", name.axis2="PC2")
}

# Save the combined figure
png("outputs/figures/niche_overlap_summary.png",
    width = 2400,
    height = 1600,
    res = 250)

plot_combined_niches()
dev.off()
plot_combined_niches()

cat("Analysis complete.\n")
cat("Table saved to outputs/tables/schoeners_D.csv\n")
cat("Figure saved to outputs/figures/niche_overlap_summary.png\n")