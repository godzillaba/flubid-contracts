# FluBid Contracts

Peer to peer NFT rentals powered by Superfluid.

FluBid enables trustless peer to peer NFT rentals with auction based pricing and continuous payment. NFT owners retain full custody while renters pay for the utility of the asset. 

All payment is done via Superfluid streams.

## Other FluBid Repositories
* [flubid-frontend](https://github.com/godzillaba/flubid-frontend)
* [flubid-subgraph](https://github.com/godzillaba/flubid-subgraph)

## Components

### Factories
Factory contracts are used to deploy new auctions and controllers via minimal clone proxies. 

`ContinuousRentalAuctionFactory`: deploys new `ContinuousRentalAuction` contracts via minimal clones proxies.

`EnglishRentalAuctionFactory`: deploys new `EnglishRentalAuction` contracts via minimal clones proxies.

### Rental Auctions
The core logic of FluBid rentals is in the Rental Auction Contracts. 
Rental Auctions are deployed via the factory contracts.

#### `ContinuousRentalAuction`
In a Continuous Rental Auction, bidders can place/remove/update bids in the form of Superfluid streams at any time and the highest bidder is the current renter. Bidding is ongoing and the renter can change instantly. 

The highest bidder (or renter) streams money to the auction owner according to their bid. All other bidders do not pay unless they become the renter.


#### `EnglishRentalAuction`
The English Rental Auction is like a standard English Auction, but for rentals. Bidders compete during the bidding phase to secure the lease with some minimum and maximum duration set by the asset owner.

### ControllerObservers
Each Rental Auction instance requires a controller to handle asset-specific logic.

Controllers are deployed via the Minimal Clones Proxy Pattern (like the Rental Auctions themselves) once per auction instance. Controllers hold the asset being rented and react to renter changes.

Currently implemented controllers:
* `DelegateCashControllerObserver`
* `LensProfileControllerObserver`
* `ERC4907ControllerObserver`