// deploy_launchpad.js
// Paano gamitin sa Remix:
// 1. I-drag/i-copy ang file na ito sa loob ng 'scripts' folder sa File Explorer ng Remix
// 2. Siguraduhing naka-set na ang Environment sa 'Injected Provider - MetaMask'
//    at tama ang network (Sepolia) sa MetaMask mo BAGO mo patakbuhin ito
// 3. I-right-click ang file sa Remix, piliin 'Run' (o gamitin ang play button sa taas)
// 4. Awtomatiko na nitong ide-deploy ang Launchpad contract gamit ang connected wallet mo

(async () => {
  try {
    console.log('Kinukuha ang compiled artifact ng Launchpad...');

    // Gamitin ang compiler API para makuha ang ABI at bytecode ng 'Launchpad' contract
    // Hinahanap sa LAHAT ng compiled files, hindi nakadepende sa eksaktong pangalan ng file
    const compiled = await remix.call('solidity', 'getCompilationResult');

    let launchpadArtifact = null;
    for (const fileName of Object.keys(compiled.data.contracts)) {
      if (compiled.data.contracts[fileName]['Launchpad']) {
        launchpadArtifact = compiled.data.contracts[fileName]['Launchpad'];
        console.log('Nahanap ang Launchpad contract sa file:', fileName);
        break;
      }
    }

    if (!launchpadArtifact) {
      console.log('ERROR: Hindi nahanap ang Launchpad contract. I-compile muna ang file (Solidity Compiler tab) bago patakbuhin ang script na ito.');
      return;
    }

    const abi = launchpadArtifact.abi;
    const bytecode = launchpadArtifact.evm.bytecode.object;

    // Gamitin ang connected wallet (MetaMask) bilang signer
    const accounts = await web3.eth.getAccounts();
    const deployer = accounts[0];
    console.log('Gagamit ng account:', deployer);

    const balance = await web3.eth.getBalance(deployer);
    console.log('Balance:', web3.utils.fromWei(balance, 'ether'), 'ETH');

    if (balance === '0') {
      console.log('ERROR: Walang balance ang account na ito sa kasalukuyang network. Siguraduhing tama ang network sa MetaMask.');
      return;
    }

    // I-deploy ang contract: constructor(address _protocolFeeRecipient)
    const contract = new web3.eth.Contract(abi);
    console.log('Nagde-deploy... kumpirmahin sa MetaMask popup.');

    const deployed = await contract
      .deploy({
        data: '0x' + bytecode,
        arguments: [deployer], // sarili mong address bilang protocol fee recipient
      })
      .send({ from: deployer });

    console.log('SUCCESSFUL! Deployed Launchpad address:', deployed.options.address);
    console.log('I-save ang address na ito - gagamitin mo ito sa CONFIG ng frontend/index.html');
  } catch (err) {
    console.log('May error:', err.message || err);
  }
})();