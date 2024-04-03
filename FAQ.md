# Frequently Asked Questions (FAQ)

## How do I install Terraform Inventory?

### Option 1: Direct Binary Download (No Go Required)

1. **Download the latest binary** for your OS from the [terraform-inventory releases page](https://github.com/adammck/terraform-inventory/releases).
   - For Linux x64, you might use:
     ```bash
     wget https://github.com/adammck/terraform-inventory/releases/download/v0.10/terraform-inventory_v0.10_linux_amd64.zip
     ```

2. **Extract the binary** and move it to `/usr/local/bin`:
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
