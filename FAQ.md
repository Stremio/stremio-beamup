# Frequently Asked Questions (FAQ)

## How do I install Terraform Inventory?

### Option 1: Direct Binary Download (No Go Required)

1. **Download the latest binary** for your OS from the [terraform-inventory releases page](https://github.com/adammck/terraform-inventory/releases).
   - For Linux x64, you might use:
     ```bash
     wget https://github.com/adammck/terraform-inventory/releases/download/v0.10/terraform-inventory_v0.10_linux_amd64.zip
     ```

2. **Extract the binary** and move it to `/usr/local/bin` and update the terraform var `terraform_provider_path` accordingly:
   ```bash
   unzip terraform-inventory_v0.10_linux_amd64.zip
   sudo mv terraform-inventory /usr/local/bin/
   ```

3. **Verify installation** by checking the version:
   ```bash
   terraform-inventory -version
   ```

### Option 2: Install Using Go

1. **Install Go** following the official [Go installation instructions](https://golang.org/doc/install) or by using the package manager of your OS.

2. **Install `terraform-inventory`** from latest commit from `master` (or main):
   ```bash
   go install github.com/adammck/terraform-inventory@master
   ```

3. **Ensure** `$(go env GOPATH)/bin` **is in your PATH**:
   - Add to `~/.bashrc` or `~/.profile` and reload:
     ```bash
     export PATH=$PATH:$(go env GOPATH)/bin
     source ~/.bashrc
     ```

4. **Verify installation** by checking the version:
   ```bash
   terraform-inventory -version
   ```

Choose the option that best fits your setup needs. The direct download method is quicker if Go isn't required for other purposes, while installing via Go might be preferable for those already using Go for development.

"**Note on Customization:** You can specify a custom path for `terraform-inventory` by updating the `terraform_inventory_path` Terraform variable as needed."

## How to use CherryServers Terraform provider when it is not available in Terraform Registry:

1. **Setup CherryServers Provider for Terraform**:
   When the provider is not available on the Terraform Registry: [CherryServers provider](https://github.com/hashicorp/terraform-provider-cherryservers) because it is not being actively updated, you'll need to install it manually by following these steps:
   
   - **Download CherryServers Provider**: Navigate to the [CherryServers Download Page](http://downloads.cherryservers.com/other/terraform/) and download the file named `terraform-provider-cherryservers`.
   
   - **Place the File**: Move the downloaded `terraform-provider-cherryservers` file to the following directory structure (this is for Linux users):
     ```bash
     ~/.terraform.d/plugins/terraform.local/local/cherryservers/1.0.0/linux_amd64/
     ```

   - **Define the Provider in the `main.tf` File**: Define the provider in the `main.tf` file as follows:
     ```hcl
     terraform {
       required_providers {
         cherryservers = {
           source  = "terraform.local/local/cherryservers"
           version = "1.0.0"
         }
       }
     }
     ```

2. **Initialize Terraform**: Run the following command to initialize Terraform with the new provider:
   ```bash
   terraform init

