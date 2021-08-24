pkgs: {

  deploymentName = "shelley-qa";
  environmentName = "shelley_qa";

  topology = import ./topologies/shelley-qa.nix pkgs;
  environmentConfig = pkgs.iohkNix.cardanoLib.environments.shelley_qa;

  withFaucet = true;
  withExplorer = true;
  explorerBackendsInContainers = true;
  explorerBackends = with pkgs.globals; {
    a = explorer10;
    b = explorer10;
  };
  withCardanoDBExtended = true;
  withSmash = true;
  withSubmitApi = true;
  faucetHostname = "faucet";
  minCpuPerInstance = 1;
  minMemoryPerInstance = 4;

  ec2 = {
    credentials = {
      accessKeyIds = {
        IOHK = "dev-deployer";
        dns = "dev-deployer";
      };
    };
  };
}
